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

	result, err := r.runToolWithHooks(ctx, sessionKey, userID, name, args, iter, seqLen, paramsHash, hashErr != nil)
	if err != nil {
		return "", err
	}

	return TruncateToolResult(result, r.MaxToolResultBytes), nil
}

func (r *AgentRunner) runToolWithHooks(ctx context.Context, sessionKey, userID, name string, args map[string]any, iter, seqLen int, paramsHash string, hashErr bool) (string, error) {
	override, err := r.preToolStep(ctx, sessionKey, name, args, paramsHash)
	if err != nil {
		return "", fmt.Errorf("pre-tool hook: %w", err)
	}
	if override != "" {
		return override, nil
	}

	result, execErr := r.mainToolStep(ctx, sessionKey, userID, name, args, iter, seqLen, paramsHash, hashErr)

	if execErr != nil {
		if errors.Is(execErr, context.Canceled) ||
			errors.Is(execErr, context.DeadlineExceeded) ||
			errors.Is(execErr, agent.ErrToolDenied) {
			return "", execErr
		}
		if bot.IsCronSession(sessionKey) {
			return "", fmt.Errorf("tool failure in fail-closed cron session [%s]: %w", name, execErr)
		}
		return r.handleCategoryAError(sessionKey, name, paramsHash, result, execErr), nil
	}

	if r.Hooks != nil {
		result = r.runPostToolHooks(ctx, name, result)
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

func (r *AgentRunner) preToolStep(ctx context.Context, sessionKey, name string, args map[string]any, paramsHash string) (string, error) {
	if r.Hooks == nil {
		return "", nil
	}
	override, err := r.Hooks.RunPreTool(ctx, sessionKey, name, args)
	if err != nil {
		return "", fmt.Errorf("pre tool hook: %w", err)
	}
	if override != "" {
		slog.Debug("runner: tool pre-hook override",
			slog.String("session", sessionKey),
			slog.String("tool", name),
			slog.String("params_hash", paramsHash),
			slog.String("result", override),
		)
		return override, nil
	}
	return "", nil
}

func (r *AgentRunner) mainToolStep(ctx context.Context, sessionKey, userID, name string, args map[string]any, iter, seqLen int, paramsHash string, hashErr bool) (string, error) {
	start := time.Now()
	var idemKey string
	if !hashErr {
		idemKey = fmt.Sprintf("%s-%d-%d-%s-%s", sessionKey, iter, seqLen, name, paramsHash)
	}
	result, execErr := r.executeTool(ctx, sessionKey, userID, idemKey, name, args, paramsHash)
	if execErr == nil {
		slog.Info("runner: tool execution completed",
			slog.String("session", sessionKey),
			slog.String("tool", name),
			slog.String("params_hash", paramsHash),
			slog.Int64("duration_ms", time.Since(start).Milliseconds()),
			slog.Int("result_len", len(result)),
		)
	}
	return result, execErr
}

func (r *AgentRunner) executeTool(ctx context.Context, sessionKey, userID, idemKey, name string, args map[string]any, paramsHash string) (string, error) {
	if !r.SideEffectingTools[name] || r.IdempStore == nil {
		return r.executeToolInner(ctx, sessionKey, userID, name, args)
	}

	if paramsHash == "" {
		var err error
		paramsHash, err = agentctx.HashParams(args)
		if err != nil {
			return "", fmt.Errorf("executeTool: hash params: %w", err)
		}
	}

	checkResult, err := r.IdempStore.Check(ctx, idemKey, name, paramsHash)
	if err != nil {
		return "", fmt.Errorf("executeTool: %w", err)
	}

	if checkResult.Found {
		slog.Debug("executeTool: idempotency cache hit", "tool", name, "key", idemKey)
		return checkResult.CachedResult, nil
	}

	result, execErr := r.executeToolInner(ctx, sessionKey, userID, name, args)
	if execErr == nil {
		if storeErr := r.IdempStore.Store(ctx, idemKey, name, paramsHash, result, sessionKey); storeErr != nil {
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
