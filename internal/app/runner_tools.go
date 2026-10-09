package app

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/bot"
	agentctx "github.com/allthingscode/gobot/internal/context"
)

// toolCallState carries the local state for one tool invocation.
type toolCallState struct {
	sessionKey string
	userID     string
	name       string
	args       map[string]any
	iter       int
	seqLen     int
	paramsHash string
	hashFailed bool
	idemKey    string
}

func (r *AgentRunner) processToolCalls(ctx context.Context, sessionKey, userID string, toolCalls []agentctx.ToolCall, iter int, toolSeq *[]string) ([]agentctx.StrategicMessage, error) {
	messages := make([]agentctx.StrategicMessage, 0, len(toolCalls))
	for _, tc := range toolCalls {
		name := tc.Name
		args := tc.Args

		var toolCallID *string
		if tc.ID != "" {
			id := tc.ID
			toolCallID = &id
		}

		*toolSeq = append(*toolSeq, name)
		callCtx, meta := withToolMeta(ctx)
		result, err := r.executeSingleToolCall(callCtx, sessionKey, userID, name, args, iter, len(*toolSeq))
		if err != nil {
			return nil, err
		}
		result = formatToolMetaBlock(result, meta)

		messages = append(messages, agentctx.StrategicMessage{
			Role:       agentctx.RoleTool,
			Name:       &name,
			Content:    &agentctx.MessageContent{Str: &result},
			ToolCallID: toolCallID,
		})
	}
	return messages, nil
}

func (r *AgentRunner) executeSingleToolCall(ctx context.Context, sessionKey, userID, name string, args map[string]any, iter, seqLen int) (string, error) {
	paramsHash, hashErr := agentctx.HashParams(args)
	if hashErr != nil {
		slog.Warn("runner: failed to hash tool params, skipping idempotency check",
			slog.String("session", sessionKey),
			slog.String("tool", name),
			slog.Any("err", hashErr),
		)
	}

	slog.Info("runner: tool call",
		slog.String("session", sessionKey),
		slog.String("tool", name),
		slog.String("params_hash", paramsHash),
		slog.Int("iter", iter),
	)

	result, err := r.runToolWithHooks(ctx, toolCallState{
		sessionKey: sessionKey, userID: userID, name: name, args: args,
		iter: iter, seqLen: seqLen, paramsHash: paramsHash, hashFailed: hashErr != nil,
	})
	if err != nil {
		return "", err
	}

	return TruncateToolResult(result, r.MaxToolResultBytes), nil
}

func (r *AgentRunner) runToolWithHooks(ctx context.Context, call toolCallState) (string, error) {
	override, err := r.preToolStep(ctx, call)
	if err != nil {
		return "", fmt.Errorf("pre-tool hook: %w", err)
	}
	if override != "" {
		return override, nil
	}

	result, execErr := r.mainToolStep(ctx, call)

	if execErr != nil {
		if errors.Is(execErr, context.Canceled) ||
			errors.Is(execErr, context.DeadlineExceeded) ||
			errors.Is(execErr, agent.ErrToolDenied) {
			return "", execErr
		}
		if bot.IsCronSession(call.sessionKey) {
			return "", fmt.Errorf("tool failure in fail-closed cron session [%s]: %w", call.name, execErr)
		}
		return r.handleCategoryAError(call.sessionKey, call.name, call.paramsHash, result, execErr), nil
	}

	if r.Hooks != nil {
		result = r.runPostToolHooks(ctx, call.name, result)
	}

	return result, nil
}

func (r *AgentRunner) handleCategoryAError(sessionKey, name, paramsHash, result string, err error) string {
	slog.Error("runner: tool execution failed",
		slog.String("session", sessionKey),
		slog.String("tool", name),
		slog.String("params_hash", paramsHash),
		slog.Any("err", err),
		slog.String("output", result),
	)

	prefix := ""
	if result != "" {
		prefix = result + "\n"
	}

	return fmt.Sprintf("%sTOOL_ERROR [%s]: %v\n\nCRITICAL INSTRUCTION: The tool failed to provide the requested information. You MUST NOT use your internal training data, previous knowledge, or memory to 'guess' or 'hallucinate' the missing data. If the information was essential, simply inform the user that it is currently unavailable due to a technical error. Do NOT invent results or model names.", prefix, name, err)
}

func (r *AgentRunner) runPostToolHooks(ctx context.Context, name, result string) string {
	if r.Hooks == nil {
		return result
	}
	anyResult := r.Hooks.RunPostTool(ctx, name, result)
	if s, ok := anyResult.(string); ok {
		return s
	}
	return fmt.Sprintf("%v", anyResult)
}

func (r *AgentRunner) preToolStep(ctx context.Context, call toolCallState) (string, error) {
	if r.Hooks == nil {
		return "", nil
	}
	override, err := r.Hooks.RunPreTool(ctx, call.sessionKey, call.name, call.args)
	if err != nil {
		return "", fmt.Errorf("pre tool hook: %w", err)
	}
	if override != "" {
		slog.Debug("runner: tool pre-hook override",
			slog.String("session", call.sessionKey),
			slog.String("tool", call.name),
			slog.String("params_hash", call.paramsHash),
			slog.String("result", override),
		)
		return override, nil
	}
	return "", nil
}

func (r *AgentRunner) mainToolStep(ctx context.Context, call toolCallState) (string, error) {
	start := time.Now()
	if !call.hashFailed {
		call.idemKey = fmt.Sprintf("%s-%d-%d-%s-%s", call.sessionKey, call.iter, call.seqLen, call.name, call.paramsHash)
	}
	result, execErr := r.executeToolCall(ctx, call)
	if execErr == nil {
		slog.Info("runner: tool execution completed",
			slog.String("session", call.sessionKey),
			slog.String("tool", call.name),
			slog.String("params_hash", call.paramsHash),
			slog.Int64("duration_ms", time.Since(start).Milliseconds()),
			slog.Int("result_len", len(result)),
		)
	}
	return result, execErr
}

func (r *AgentRunner) executeTool(ctx context.Context, sessionKey, userID, idemKey, name string, args map[string]any, paramsHash string) (string, error) {
	return r.executeToolCall(ctx, toolCallState{
		sessionKey: sessionKey, userID: userID, idemKey: idemKey,
		name: name, args: args, paramsHash: paramsHash,
	})
}

func (r *AgentRunner) executeToolCall(ctx context.Context, call toolCallState) (string, error) {
	if !r.SideEffectingTools[call.name] || r.IdempStore == nil {
		return r.executeToolInner(ctx, call.sessionKey, call.userID, call.name, call.args)
	}

	if call.paramsHash == "" {
		var err error
		call.paramsHash, err = agentctx.HashParams(call.args)
		if err != nil {
			return "", fmt.Errorf("executeTool: hash params: %w", err)
		}
	}

	checkResult, err := r.IdempStore.Check(ctx, call.idemKey, call.name, call.paramsHash)
	if err != nil {
		return "", fmt.Errorf("executeTool: %w", err)
	}

	if checkResult.Found {
		slog.Debug("executeTool: idempotency cache hit", "tool", call.name, "key", call.idemKey)
		return checkResult.CachedResult, nil
	}

	result, execErr := r.executeToolInner(ctx, call.sessionKey, call.userID, call.name, call.args)
	if execErr == nil {
		if storeErr := r.IdempStore.Store(ctx, call.idemKey, call.name, call.paramsHash, result, call.sessionKey); storeErr != nil {
			slog.Warn("executeTool: failed to store idempotency key", "err", storeErr)
		}
	}
	return result, execErr
}

func (r *AgentRunner) executeToolInner(ctx context.Context, sessionKey, userID, name string, args map[string]any) (result string, err error) {
	defer func() {
		if rec := recover(); rec != nil {
			slog.Error("runner: tool panic recovered", "session", sessionKey, "tool", name, "panic", rec)
			err = fmt.Errorf("tool %s panicked: %v", name, rec)
		}
	}()

	t, ok := r.ToolsByName[name]
	if !ok {
		return "", fmt.Errorf("%w: %s", agent.ErrUnknownTool, name)
	}

	if r.Tracer != nil {
		resp, err := r.Tracer.TraceToolExecution(ctx, sessionKey, name, func(ctx context.Context) (string, error) {
			return t.Execute(ctx, sessionKey, userID, args)
		})
		if err != nil {
			return resp, fmt.Errorf("trace tool execution: %w", err)
		}
		return resp, nil
	}
	resp, err := t.Execute(ctx, sessionKey, userID, args)
	if err != nil {
		return resp, fmt.Errorf("execute tool: %w", err)
	}
	return resp, nil
}
