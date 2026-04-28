package app

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"
	"unicode/utf8"

	"golang.org/x/time/rate"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/memory"
	"github.com/allthingscode/gobot/internal/memory/vector"
	"github.com/allthingscode/gobot/internal/observability"
	"github.com/allthingscode/gobot/internal/provider"
	"github.com/allthingscode/gobot/internal/reflection"
	"github.com/allthingscode/gobot/internal/resilience"
)

// ToolLimitConfigurable is an optional interface that runners can implement
// to allow the tool to set their internal iteration limit.
type ToolLimitConfigurable interface {
	SetMaxToolIterations(int)
}

// AgentRunner implements the agent.Runner interface using a provider.Provider.
type AgentRunner struct {
	Prov                provider.Provider
	Model               string
	SystemPrompt        string
	MemStore            *memory.MemoryStore                     // may be nil; shared single-user RAG store
	MemStoreProvider    func(userID string) *memory.MemoryStore // may be nil; F-105 per-user store factory
	VecStore            *vector.Store                           // F-030: Semantic memory
	EmbedProv           vector.EmbeddingProvider                // F-030: Semantic memory
	Cfg                 *config.Config                          // F-030: Configuration
	ToolsByName         map[string]Tool                         // registered tools exposed to the provider
	Breaker             *resilience.Breaker                     // circuit breaker for API calls
	Limiter             *rate.Limiter                           // token-bucket rate limiter
	Hooks               *agent.Hooks                            // may be nil; set via SetHooks
	Tracer              *observability.DispatchTracer
	IdempStore          *agentctx.IdempotencyStore // may be nil; idempotency for side-effecting tools
	SideEffectingTools  map[string]bool            // C-142: lookup for tools that modify external state
	MaxToolIterations   int
	MaxTokens           int
	MaxToolResultBytes  int
	EnableReflection    bool // opt-in; off by default for cost control
	MaxReflectionRounds int  // default 1 â†’ â‰¤2x token overhead
}

// NewAgentRunner creates a new AgentRunner for the given provider and model.
func NewAgentRunner(prov provider.Provider, model, systemPrompt string, cfg *config.Config) *AgentRunner {
	maxFail, window, timeout := cfg.Breaker(prov.Name())
	return &AgentRunner{
		Prov:                prov,
		Model:               model,
		SystemPrompt:        systemPrompt,
		Cfg:                 cfg,
		Breaker:             resilience.New(prov.Name(), maxFail, window, timeout),
		Limiter:             rate.NewLimiter(rate.Every(time.Second), 3),
		MaxToolIterations:   cfg.EffectiveMaxToolIterations(),
		MaxTokens:           cfg.MaxTokens(),
		MaxToolResultBytes:  cfg.MaxToolResultBytes(),
		EnableReflection:    false,
		MaxReflectionRounds: 1,
	}
}

// RunText performs a single-turn, text-only LLM call without tool use.
func (r *AgentRunner) RunText(ctx context.Context, sessionKey, prompt, modelOverride string) (string, error) {
	model := r.Model
	if modelOverride != "" {
		model = modelOverride
	}
	req := provider.ChatRequest{
		Model:    model,
		Messages: []agentctx.StrategicMessage{{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: &prompt}}},
	}
	resp, err := r.RetryChat(ctx, sessionKey, req)
	if err != nil {
		return "", fmt.Errorf("RunText: %w", err)
	}
	return ExtractText(resp.Message), nil
}

// SetHooks configures lifecycle hooks for this runner.
func (r *AgentRunner) SetHooks(h *agent.Hooks) {
	r.Hooks = h
}

// SetTracer configures the observability tracer for this runner.
func (r *AgentRunner) SetTracer(t *observability.DispatchTracer) {
	r.Tracer = t
}

// SetIdempotencyStore configures the idempotency store for side-effecting tools.
func (r *AgentRunner) SetIdempotencyStore(store *agentctx.IdempotencyStore) {
	r.IdempStore = store
}

// SetMemoryStoreProvider configures a factory that returns a per-user MemoryStore.
func (r *AgentRunner) SetMemoryStoreProvider(fn func(userID string) *memory.MemoryStore) {
	r.MemStoreProvider = fn
}

// SetMaxToolIterations sets the maximum number of tool call turns allowed in a single Run.
func (r *AgentRunner) SetMaxToolIterations(n int) {
	r.MaxToolIterations = n
}

// SetTools registers a list of tools with the runner.
func (r *AgentRunner) SetTools(tools []Tool) {
	m := make(map[string]Tool, len(tools))
	se := make(map[string]bool)
	for _, t := range tools {
		decl := t.Declaration()
		name := decl.Name
		if _, dup := m[name]; dup {
			slog.Warn("runner: duplicate tool name registered, later registration wins", "tool", name)
		}
		m[name] = t
		if decl.SideEffecting {
			se[name] = true
		}
	}
	r.ToolsByName = m
	r.SideEffectingTools = se
}

// Run executes the tool-call/response loop until the provider returns a terminal text response.
func (r *AgentRunner) Run(ctx context.Context, sessionKey, userID string, messages []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error) {
	memStore := r.MemStore
	if r.MemStoreProvider != nil && userID != "" {
		memStore = r.MemStoreProvider(userID)
	}

	sysPrompt := r.buildSystemPrompt(ctx, sessionKey, messages, memStore)
	userText := LastUserText(messages)
	rubric := r.generateReflectionRubric(ctx, sessionKey, userText)

	toolDecls := make([]provider.ToolDeclaration, 0, len(r.ToolsByName))
	for _, t := range r.ToolsByName {
		toolDecls = append(toolDecls, t.Declaration())
	}

	toolSeq := make([]string, 0, r.MaxToolIterations*2)
	reflectionRounds := 0

	for iter := 0; iter < r.MaxToolIterations; iter++ {
		req := provider.ChatRequest{
			Model:             r.Model,
			Messages:          messages,
			SystemInstruction: sysPrompt,
			Tools:             toolDecls,
			MaxTokens:         r.MaxTokens,
		}

		slog.Debug("runner: calling provider.Chat", "session", sessionKey, "provider", r.Prov.Name(), "model", r.Model, "messages", len(messages), "iter", iter)

		resp, err := r.RetryChat(ctx, sessionKey, req)
		if err != nil {
			return "", nil, fmt.Errorf("chat: %w", err)
		}

		messages = append(messages, resp.Message)

		if len(resp.Message.ToolCalls) == 0 {
			text, done := r.handleTerminalResponse(ctx, sessionKey, userText, rubric, resp.Message, &messages, &reflectionRounds)
			if done {
				return text, messages, nil
			}
			continue
		}

		newMsgs, err := r.processToolCalls(ctx, sessionKey, userID, resp.Message.ToolCalls, iter, &toolSeq)
		if err != nil {
			return "", nil, err
		}
		messages = append(messages, newMsgs...)
	}

	slog.Error("runner: tool loop exhausted",
		"session", sessionKey,
		"iterations", r.MaxToolIterations,
		"tool_sequence", strings.Join(toolSeq, " -> "),
	)
	return "", nil, fmt.Errorf("runner: tool dispatch loop exceeded %d iterations", r.MaxToolIterations)
}

func (r *AgentRunner) buildSystemPrompt(ctx context.Context, sessionKey string, messages []agentctx.StrategicMessage, memStore *memory.MemoryStore) string {
	sysPrompt := r.SystemPrompt
	if memStore != nil {
		if userText := LastUserText(messages); !memory.ShouldSkipRAG(userText) {
			ragBlock := r.getRagBlock(ctx, sessionKey, userText, memStore)
			if ragBlock != "" {
				if sysPrompt != "" {
					sysPrompt = ragBlock + "\n\n" + sysPrompt
				} else {
					sysPrompt = ragBlock
				}
			}
		}
	}

	if r.Hooks != nil {
		sysPrompt = r.Hooks.RunPrePrompt(ctx, sysPrompt)
	}
	return sysPrompt
}

func (r *AgentRunner) getRagBlock(ctx context.Context, sessionKey, userText string, memStore *memory.MemoryStore) string {
	var filtered []map[string]any

	if r.Cfg.VectorSearchEnabled() && r.VecStore != nil && r.EmbedProv != nil {
		filtered = r.hybridRagSearch(ctx, sessionKey, userText, memStore)
	} else {
		filtered = r.ftsSearch(ctx, userText, sessionKey, memStore)
	}

	block, n := memory.FormatRAGBlock(filtered)
	if n > 0 {
		slog.Debug("runner: injecting RAG context", "entries", n)
		return block
	}
	return ""
}

func (r *AgentRunner) hybridRagSearch(ctx context.Context, sessionKey, userText string, memStore *memory.MemoryStore) []map[string]any {
	var hybridResults []vector.HybridResult
	var err error
	if r.Tracer != nil {
		err = r.Tracer.TraceMemorySearch(ctx, "hybrid", func(ctx context.Context) error {
			var err2 error
			hybridResults, err2 = vector.HybridSearch(ctx, memStore, r.VecStore, r.EmbedProv, userText, sessionKey, 5)
			if err2 != nil {
				return fmt.Errorf("hybrid search: %w", err2)
			}
			return nil
		})
	} else {
		var err2 error
		hybridResults, err2 = vector.HybridSearch(ctx, memStore, r.VecStore, r.EmbedProv, userText, sessionKey, 5)
		if err2 != nil {
			err = fmt.Errorf("hybrid search: %w", err2)
		}
	}

	if err == nil {
		filtered := make([]map[string]any, 0, len(hybridResults))
		for _, res := range hybridResults {
			filtered = append(filtered, map[string]any{
				"content": res.Content,
				"score":   res.Score,
			})
		}
		return filtered
	}

	slog.Warn("runner: hybrid RAG search failed, falling back to FTS5", "err", err)
	return r.ftsSearch(ctx, userText, sessionKey, memStore)
}

func (r *AgentRunner) ftsSearch(ctx context.Context, userText, sessionKey string, memStore *memory.MemoryStore) []map[string]any {
	var results []map[string]any
	var err error

	if r.Tracer != nil {
		err = r.Tracer.TraceMemorySearch(ctx, "fts", func(ctx context.Context) error {
			var err2 error
			results, err2 = memStore.Search(ctx, userText, sessionKey, 10)
			if err2 != nil {
				return fmt.Errorf("fts search: %w", err2)
			}
			return nil
		})
	} else {
		results, err = memStore.Search(ctx, userText, sessionKey, 10)
	}

	if err != nil {
		slog.Error("runner: FTS search failed", "err", err, "session", sessionKey)
		return nil
	}

	if len(results) > 0 {
		return memory.FilterRAGResults(results, 0.0)
	}
	return nil
}

func (r *AgentRunner) generateReflectionRubric(ctx context.Context, sessionKey, userText string) map[string]any {
	if !r.EnableReflection || userText == "" {
		return nil
	}
	planPrompt := reflection.GenerateRubricPrompt(userText)
	planStr, planErr := r.RunText(ctx, sessionKey, planPrompt, "")
	if planErr != nil {
		return nil
	}
	parsed, ok := reflection.ParseJSONResponse(planStr)
	if !ok {
		return nil
	}
	slog.Debug("runner: planning rubric generated", "session", sessionKey)
	return parsed
}

func (r *AgentRunner) performReflectionAudit(ctx context.Context, sessionKey, userText string, rubric map[string]any, text string, reflectionRounds *int) (agentctx.StrategicMessage, bool) {
	criticPrompt := reflection.GenerateCriticPrompt(userText, rubric, text)
	criticStr, criticErr := r.RunText(ctx, sessionKey, criticPrompt, "")
	if criticErr != nil {
		return agentctx.StrategicMessage{}, true
	}

	report, ok := reflection.ParseJSONResponse(criticStr)
	if !ok {
		return agentctx.StrategicMessage{}, true
	}

	score := reflection.CalculateTotalScore(report, rubric)
	threshold := 0.7
	if t, ok := rubric["success_threshold"].(float64); ok {
		threshold = t
	}

	if score < threshold {
		*reflectionRounds++
		correction := BuildCorrectionMessage(report)
		slog.Info("runner: reflection backtrack triggered",
			"session", sessionKey,
			"score", score,
			"threshold", threshold,
			"round", *reflectionRounds,
		)
		return agentctx.StrategicMessage{
			Role:    agentctx.RoleUser,
			Content: &agentctx.MessageContent{Str: &correction},
		}, false
	}

	slog.Debug("runner: reflection passed", "session", sessionKey, "score", score)
	return agentctx.StrategicMessage{}, true
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
		result, err := r.executeSingleToolCall(ctx, sessionKey, userID, name, args, iter, len(*toolSeq))
		if err != nil {
			return nil, err
		}

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

func (r *AgentRunner) handleTerminalResponse(ctx context.Context, sessionKey, userText string, rubric map[string]any, respMsg agentctx.StrategicMessage, messages *[]agentctx.StrategicMessage, reflectionRounds *int) (string, bool) {
	text := ExtractText(respMsg)
	if r.EnableReflection && rubric != nil && *reflectionRounds < r.MaxReflectionRounds {
		if msg, ok := r.performReflectionAudit(ctx, sessionKey, userText, rubric, text, reflectionRounds); !ok {
			*messages = append(*messages, msg)
			return "", false
		}
	}
	return text, true
}

// RetryChat calls prov.Chat with exponential backoff on transient errors.
func (r *AgentRunner) RetryChat(ctx context.Context, sessionKey string, req provider.ChatRequest) (*provider.ChatResponse, error) {
	const maxGenRetries = 3
	const initialDelay = 1 * time.Second
	const maxDelay = 30 * time.Second

	delay := initialDelay
	var lastErr error
	for attempt := 0; attempt <= maxGenRetries; attempt++ {
		if attempt > 0 {
			if err := r.waitBeforeRetry(ctx, lastErr, attempt, &delay, maxDelay); err != nil {
				return nil, err
			}
		}

		resp, err := r.attemptChat(ctx, sessionKey, attempt, req)
		if err == nil {
			return resp, nil
		}

		if !r.shouldRetry(err) {
			return nil, err
		}
		lastErr = err
	}
	return nil, fmt.Errorf("%d retries exhausted: %w", maxGenRetries, lastErr)
}

func (r *AgentRunner) waitBeforeRetry(ctx context.Context, lastErr error, attempt int, delay *time.Duration, maxDelay time.Duration) error {
	slog.Warn("runner: transient error, retrying", "attempt", attempt, "delay", *delay, "err", lastErr)
	select {
	case <-ctx.Done():
		return fmt.Errorf("context: %w", ctx.Err())
	case <-time.After(*delay):
	}
	*delay *= 2
	if *delay > maxDelay {
		*delay = maxDelay
	}
	return nil
}

func (r *AgentRunner) attemptChat(ctx context.Context, sessionKey string, attempt int, req provider.ChatRequest) (*provider.ChatResponse, error) {
	if waitErr := r.Limiter.Wait(ctx); waitErr != nil {
		return nil, fmt.Errorf("rate limit wait: %w", waitErr)
	}

	var resp *provider.ChatResponse
	fn := func(ctx context.Context) error {
		return r.Breaker.Execute(func() error {
			var callErr error
			resp, callErr = r.Prov.Chat(ctx, req)
			if callErr != nil {
				return fmt.Errorf("provider chat: %w", callErr)
			}
			return nil
		})
	}

	var err error
	if r.Tracer != nil {
		err = r.Tracer.TraceProviderCall(ctx, sessionKey, attempt, fn)
	} else {
		err = fn(ctx)
	}

	if err == nil {
		if r.Tracer != nil && resp != nil && resp.Usage.TotalTokens > 0 {
			r.Tracer.RecordTokens(ctx, int64(resp.Usage.TotalTokens))
		}
		return resp, nil
	}
	return nil, err
}

func (r *AgentRunner) shouldRetry(err error) bool {
	if errors.Is(err, resilience.ErrCircuitOpen) {
		return false
	}
	return bot.IsTransientError(err)
}

// ExtractText joins all non-empty text parts from a StrategicMessage.
func ExtractText(msg agentctx.StrategicMessage) string {
	if msg.Content == nil {
		return ""
	}
	if msg.Content.Str != nil {
		return *msg.Content.Str
	}
	var sb strings.Builder
	for _, item := range msg.Content.Items {
		if item.Text != nil {
			sb.WriteString(item.Text.Text)
		}
	}
	return sb.String()
}

// LastUserText returns the content of the most recent user message in the history.
func LastUserText(messages []agentctx.StrategicMessage) string {
	for i := len(messages) - 1; i >= 0; i-- {
		if messages[i].Role == agentctx.RoleUser && messages[i].Content != nil && messages[i].Content.Str != nil {
			return *messages[i].Content.Str
		}
	}
	return ""
}

// BuildCorrectionMessage formats a critic report into a prompt for the agent to revise its response.
func BuildCorrectionMessage(report map[string]any) string {
	feedback, _ := report["feedback"].(string)
	corrections, _ := report["required_corrections"].([]any)

	var sb strings.Builder
	sb.WriteString("The previous response did not fully satisfy the task requirements.\n")
	if feedback != "" {
		sb.WriteString("Critic feedback: ")
		sb.WriteString(feedback)
		sb.WriteString("\n")
	}
	if len(corrections) > 0 {
		sb.WriteString("Required corrections:\n")
		for i, c := range corrections {
			if s, ok := c.(string); ok {
				fmt.Fprintf(&sb, "%d. %s\n", i+1, s)
			}
		}
	}
	sb.WriteString("Please revise your response to address the above.")
	return sb.String()
}

// TruncateToolResult shortens a tool result string to maxBytes if it exceeds the limit.
func TruncateToolResult(result string, maxBytes int) string {
	if maxBytes <= 0 || len(result) <= maxBytes {
		return result
	}
	slog.Info("runner: tool result truncated", "max_bytes", maxBytes, "original_size", len(result))
	idx := maxBytes
	for idx > 0 && !utf8.RuneStart(result[idx]) {
		idx--
	}
	const truncationNotice = "\n\n[... truncated: result exceeded %d bytes ...]"
	return result[:idx] + fmt.Sprintf(truncationNotice, maxBytes)
}

// GenerateIdempotencyKey creates a random UUID-like string for tracking tool side effects.
func GenerateIdempotencyKey() string {
	bytes := make([]byte, 16)
	if _, err := rand.Read(bytes); err != nil {
		// Fallback to timestamp-based key if random fails.
		return fmt.Sprintf("idem-%d", time.Now().UnixNano())
	}
	// Set version (4) and variant bits.
	bytes[6] = (bytes[6] & 0x0f) | 0x40 // version 4
	bytes[8] = (bytes[8] & 0x3f) | 0x80 // variant 10
	return fmt.Sprintf("%x-%x-%x-%x-%x",
		bytes[0:4], bytes[4:6], bytes[6:8], bytes[8:10], bytes[10:])
}
