package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
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
	"github.com/allthingscode/gobot/internal/doctor"
	"github.com/allthingscode/gobot/internal/memory"
	"github.com/allthingscode/gobot/internal/memory/consolidator"
	"github.com/allthingscode/gobot/internal/memory/vector"
	"github.com/allthingscode/gobot/internal/observability"
	"github.com/allthingscode/gobot/internal/provider"
	"github.com/allthingscode/gobot/internal/reflection"
	"github.com/allthingscode/gobot/internal/resilience"
	"github.com/spf13/cobra"
)

// geminiRunner implements the agent.Runner interface using a provider.Provider.
type geminiRunner struct {
	prov                provider.Provider
	model               string
	systemPrompt        string
	memStore            *memory.MemoryStore                     // may be nil; shared single-user RAG store
	memStoreProvider    func(userID string) *memory.MemoryStore // may be nil; F-105 per-user store factory
	vecStore            *vector.Store                           // F-030: Semantic memory
	embedProv           vector.EmbeddingProvider                // F-030: Semantic memory
	cfg                 *config.Config                          // F-030: Configuration
	toolsByName         map[string]Tool                         // registered tools exposed to the provider
	breaker             *resilience.Breaker                     // circuit breaker for API calls
	limiter             *rate.Limiter                           // token-bucket rate limiter
	hooks               *agent.Hooks                            // may be nil; set via SetHooks
	tracer              *observability.DispatchTracer
	idempStore          *agentctx.IdempotencyStore // may be nil; idempotency for side-effecting tools
	maxToolIterations   int
	maxTokens           int
	maxToolResultBytes  int
	enableReflection    bool // opt-in; off by default for cost control
	maxReflectionRounds int  // default 1 → ≤2x token overhead
}

// newGeminiRunner creates a new geminiRunner for the given provider and model.
func newGeminiRunner(prov provider.Provider, model, systemPrompt string, cfg *config.Config) *geminiRunner {
	maxFail, window, timeout := cfg.Breaker(prov.Name())
	return &geminiRunner{
		prov:         prov,
		model:        model,
		systemPrompt: systemPrompt,
		cfg:          cfg,
		// Configured circuit breaker for LLM provider.
		breaker: resilience.New(prov.Name(), maxFail, window, timeout),
		// 3 requests/second burst; conservative default.
		limiter:             rate.NewLimiter(rate.Every(time.Second), 3),
		maxToolIterations:   cfg.EffectiveMaxToolIterations(),
		maxTokens:           cfg.MaxTokens(),
		maxToolResultBytes:  cfg.MaxToolResultBytes(),
		enableReflection:    false,
		maxReflectionRounds: 1,
	}
}

// RunText performs a single-turn, text-only LLM call without tool use.
func (r *geminiRunner) RunText(ctx context.Context, sessionKey, prompt, modelOverride string) (string, error) {
	model := r.model
	if modelOverride != "" {
		model = modelOverride
	}
	req := provider.ChatRequest{
		Model:    model,
		Messages: []agentctx.StrategicMessage{{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: &prompt}}},
	}
	resp, err := r.retryChat(ctx, sessionKey, req)
	if err != nil {
		return "", fmt.Errorf("RunText: %w", err)
	}
	return extractText(resp.Message), nil
}

// SetHooks configures lifecycle hooks for this runner.
// PrePrompt hooks are applied before each Chat call.
func (r *geminiRunner) SetHooks(h *agent.Hooks) {
	r.hooks = h
}

// SetTracer configures the observability tracer for this runner.
func (r *geminiRunner) SetTracer(t *observability.DispatchTracer) {
	r.tracer = t
}

// SetIdempotencyStore configures the idempotency store for side-effecting tools.
func (r *geminiRunner) SetIdempotencyStore(store *agentctx.IdempotencyStore) {
	r.idempStore = store
}

// SetMemoryStoreProvider configures a factory that returns a per-user MemoryStore
// when multi-user workspace isolation is enabled (F-105). When set and userID is
// non-empty, Run will call this factory instead of using the shared r.memStore.
func (r *geminiRunner) SetMemoryStoreProvider(fn func(userID string) *memory.MemoryStore) {
	r.memStoreProvider = fn
}

func (r *geminiRunner) SetMaxToolIterations(n int) {
	r.maxToolIterations = n
}

// SetTools registers a list of tools with the runner, building an O(1) lookup map.
// If multiple tools have the same name, the last one registered wins and a warning is logged.
func (r *geminiRunner) SetTools(tools []Tool) {
	m := make(map[string]Tool, len(tools))
	for _, t := range tools {
		name := t.Name()
		if _, dup := m[name]; dup {
			slog.Warn("runner: duplicate tool name registered, later registration wins", "tool", name)
		}
		m[name] = t
	}
	r.toolsByName = m
}

// Run executes the tool-call/response loop until the provider returns a terminal text response.
//
// Each iteration:
//  1. Calls prov.Chat with the current messages and system prompt (including RAG).
//  2. If the response contains ToolCalls, dispatches each to the matching Tool.Execute,
//     appends the results as new "tool" messages, and loops.
//  3. If the response contains no tool calls, extracts the text and returns.
//
// Returns an error if maxToolIterations is exceeded or prov.Chat fails.
func (r *geminiRunner) Run(ctx context.Context, sessionKey, userID string, messages []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error) {
	// F-105: Resolve per-user memory store when multi-user isolation is enabled.
	memStore := r.memStore
	if r.memStoreProvider != nil && userID != "" {
		memStore = r.memStoreProvider(userID)
	}

	// 1. Build System Prompt with RAG and Hooks
	sysPrompt := r.buildSystemPrompt(ctx, sessionKey, messages, memStore)

	// Planning phase (F-049): generate a validation rubric before executing.
	userText := lastUserText(messages)
	rubric := r.generateReflectionRubric(ctx, sessionKey, userText)

	// 2. Prepare Tool Declarations
	toolDecls := make([]provider.ToolDeclaration, 0, len(r.toolsByName))
	for _, t := range r.toolsByName {
		toolDecls = append(toolDecls, t.Declaration())
	}

	// toolSeq records the tool names called across all iterations for diagnostics.
	toolSeq := make([]string, 0, r.maxToolIterations*2)

	reflectionRounds := 0

	// 3. Loop
	for iter := 0; iter < r.maxToolIterations; iter++ {
		req := provider.ChatRequest{
			Model:             r.model,
			Messages:          messages,
			SystemInstruction: sysPrompt,
			Tools:             toolDecls,
			MaxTokens:         r.maxTokens,
		}

		slog.Debug("runner: calling provider.Chat", "session", sessionKey, "provider", r.prov.Name(), "model", r.model, "messages", len(messages), "iter", iter)

		// 4. Retry + Resilience Call
		resp, err := r.retryChat(ctx, sessionKey, req)
		if err != nil {
			return "", nil, fmt.Errorf("chat: %w", err)
		}

		// 5. Append Assistant Message
		messages = append(messages, resp.Message)

		// 6. Check for Tool Calls
		if len(resp.Message.ToolCalls) == 0 {
			text, done := r.handleTerminalResponse(ctx, sessionKey, userText, rubric, resp.Message, &messages, &reflectionRounds)
			if done {
				return text, messages, nil
			}
			continue
		}

		// 7. Execute Tools
		newMsgs, err := r.processToolCalls(ctx, sessionKey, userID, resp.Message.ToolCalls, iter, &toolSeq)
		if err != nil {
			return "", nil, err
		}
		messages = append(messages, newMsgs...)
	}

	slog.Error("runner: tool loop exhausted",
		"session", sessionKey,
		"iterations", r.maxToolIterations,
		"tool_sequence", strings.Join(toolSeq, " -> "),
	)
	return "", nil, fmt.Errorf("runner: tool dispatch loop exceeded %d iterations", r.maxToolIterations)
}

func (r *geminiRunner) buildSystemPrompt(ctx context.Context, sessionKey string, messages []agentctx.StrategicMessage, memStore *memory.MemoryStore) string {
	sysPrompt := r.systemPrompt
	if memStore != nil {
		if userText := lastUserText(messages); !memory.ShouldSkipRAG(userText) {
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

	if r.hooks != nil {
		sysPrompt = r.hooks.RunPrePrompt(ctx, sysPrompt)
	}
	return sysPrompt
}

func (r *geminiRunner) getRagBlock(ctx context.Context, sessionKey, userText string, memStore *memory.MemoryStore) string {
	var filtered []map[string]any

	// F-030: Use hybrid search for RAG if enabled
	if r.cfg.VectorSearchEnabled() && r.vecStore != nil && r.embedProv != nil {
		hybridResults, err := vector.HybridSearch(ctx, memStore, r.vecStore, r.embedProv, userText, sessionKey, 5)
		if err == nil {
			// Map hybrid results to the format expected by FormatRAGBlock
			for _, res := range hybridResults {
				filtered = append(filtered, map[string]any{
					"content": res.Content,
					"score":   res.Score,
				})
			}
		} else {
			slog.Warn("runner: hybrid RAG search failed, falling back to FTS5", "err", err)
			filtered = r.ftsSearch(userText, sessionKey, memStore)
		}
	} else {
		filtered = r.ftsSearch(userText, sessionKey, memStore)
	}

	block, n := memory.FormatRAGBlock(filtered)
	if n > 0 {
		slog.Debug("runner: injecting RAG context", "entries", n)
		return block
	}
	return ""
}

func (r *geminiRunner) ftsSearch(userText, sessionKey string, memStore *memory.MemoryStore) []map[string]any {
	// F-071: Pass sessionKey to Search
	if results, _ := memStore.Search(userText, sessionKey, 5); len(results) > 0 {
		return memory.FilterRAGResults(results, 0.0)
	}
	return nil
}

func (r *geminiRunner) generateReflectionRubric(ctx context.Context, sessionKey, userText string) map[string]any {
	if !r.enableReflection || userText == "" {
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

func (r *geminiRunner) performReflectionAudit(ctx context.Context, sessionKey, userText string, rubric map[string]any, text string, reflectionRounds *int) (agentctx.StrategicMessage, bool) {
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
		correction := buildCorrectionMessage(report)
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

func (r *geminiRunner) processToolCalls(ctx context.Context, sessionKey, userID string, toolCalls []agentctx.ToolCall, iter int, toolSeq *[]string) ([]agentctx.StrategicMessage, error) {
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

func (r *geminiRunner) executeSingleToolCall(ctx context.Context, sessionKey, userID, name string, args map[string]any, iter, seqLen int) (string, error) {
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

	return truncateToolResult(result, r.maxToolResultBytes), nil
}

func (r *geminiRunner) runToolWithHooks(ctx context.Context, sessionKey, userID, name string, args map[string]any, iter, seqLen int, paramsHash string, hashErr bool) (string, error) {
	result, execErr := r.preToolStep(ctx, sessionKey, name, args, paramsHash)

	if execErr == nil && result == "" {
		result, execErr = r.mainToolStep(ctx, sessionKey, userID, name, args, iter, seqLen, paramsHash, hashErr)
	}

	if execErr != nil {
		return r.handleToolError(sessionKey, name, paramsHash, result, execErr), nil
	}

	if r.hooks != nil && result == "" {
		anyResult := r.hooks.RunPostTool(ctx, name, result)
		if s, ok := anyResult.(string); ok {
			result = s
		} else {
			// Convert non-string results back to string for the agent.
			result = fmt.Sprintf("%v", anyResult)
		}
	}

	return result, nil
}

func (r *geminiRunner) preToolStep(ctx context.Context, sessionKey, name string, args map[string]any, paramsHash string) (string, error) {
	if r.hooks == nil {
		return "", nil
	}
	override, err := r.hooks.RunPreTool(ctx, sessionKey, name, args)
	if err != nil {
		return "", err
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

func (r *geminiRunner) mainToolStep(ctx context.Context, sessionKey, userID, name string, args map[string]any, iter, seqLen int, paramsHash string, hashErr bool) (string, error) {
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

func (r *geminiRunner) handleToolError(sessionKey, name, paramsHash, result string, err error) string {
	slog.Error("runner: tool execution failed",
		slog.String("session", sessionKey),
		slog.String("tool", name),
		slog.String("params_hash", paramsHash),
		slog.Any("err", err),
	)
	if result != "" {
		return fmt.Sprintf("%s\nError: %v", result, err)
	}
	return fmt.Sprintf("Error: %v", err)
}

// executeTool dispatches a tool call to the matching registered Tool.
// For side-effecting tools, it checks the idempotency store before execution
// and caches the result to prevent duplicates on retry.
func (r *geminiRunner) executeTool(ctx context.Context, sessionKey, userID, idemKey, name string, args map[string]any, paramsHash string) (string, error) {
	// Check if this is a side-effecting tool that needs idempotency protection.
	if !isSideEffectingTool(name) || r.idempStore == nil {
		return r.executeToolInner(ctx, sessionKey, userID, name, args)
	}

	// If paramsHash not already computed by caller, compute it now.
	if paramsHash == "" {
		var err error
		paramsHash, err = agentctx.HashParams(args)
		if err != nil {
			return "", fmt.Errorf("executeTool: hash params: %w", err)
		}
	}

	// Check idempotency store.
	checkResult, err := r.idempStore.Check(ctx, idemKey, name, paramsHash)
	if err != nil {
		// Hash mismatch — same key with different params.
		return "", fmt.Errorf("executeTool: %w", err)
	}

	if checkResult.Found {
		// Cache hit — return cached result without executing.
		slog.Debug("executeTool: idempotency cache hit", "tool", name, "key", idemKey)
		return checkResult.CachedResult, nil
	}

	// Cache miss — execute the tool and store result.
	result, execErr := r.executeToolInner(ctx, sessionKey, userID, name, args)
	if execErr == nil {
		// Store result in idempotency cache.
		if storeErr := r.idempStore.Store(ctx, idemKey, name, paramsHash, result, sessionKey); storeErr != nil {
			slog.Warn("executeTool: failed to store idempotency key", "err", storeErr)
		}
	}
	return result, execErr
}

// executeToolInner is the inner implementation of executeTool without idempotency checks.
func (r *geminiRunner) executeToolInner(ctx context.Context, sessionKey, userID, name string, args map[string]any) (result string, err error) {
	defer func() {
		if rec := recover(); rec != nil {
			slog.Error("runner: tool panic recovered", "session", sessionKey, "tool", name, "panic", rec)
			err = fmt.Errorf("tool %s panicked: %v", name, rec)
		}
	}()

	t, ok := r.toolsByName[name]
	if !ok {
		return "", fmt.Errorf("unknown tool: %s", name)
	}

	if r.tracer != nil {
		return r.tracer.TraceToolExecution(ctx, sessionKey, name, func(ctx context.Context) (string, error) {
			return t.Execute(ctx, sessionKey, userID, args)
		})
	}
	return t.Execute(ctx, sessionKey, userID, args)
}

// generateIdempotencyKey generates a random UUID v4 for use as an idempotency key.
func generateIdempotencyKey() string {
	bytes := make([]byte, 16)
	if _, err := rand.Read(bytes); err != nil {
		// Fallback to timestamp-based key if random fails.
		return fmt.Sprintf("idem-%d", time.Now().UnixNano())
	}
	// Set version (4) and variant bits.
	bytes[6] = (bytes[6] & 0x0f) | 0x40 // version 4
	bytes[8] = (bytes[8] & 0x3f) | 0x80 // variant 10
	return fmt.Sprintf("%s-%s-%s-%s-%s",
		hex.EncodeToString(bytes[0:4]),
		hex.EncodeToString(bytes[4:6]),
		hex.EncodeToString(bytes[6:8]),
		hex.EncodeToString(bytes[8:10]),
		hex.EncodeToString(bytes[10:16]))
}

func (r *geminiRunner) handleTerminalResponse(ctx context.Context, sessionKey, userText string, rubric map[string]any, respMsg agentctx.StrategicMessage, messages *[]agentctx.StrategicMessage, reflectionRounds *int) (string, bool) {
	text := extractText(respMsg)
	if r.enableReflection && rubric != nil && *reflectionRounds < r.maxReflectionRounds {
		if msg, ok := r.performReflectionAudit(ctx, sessionKey, userText, rubric, text, reflectionRounds); !ok {
			*messages = append(*messages, msg)
			return "", false
		}
	}
	return text, true
}

// retryChat calls prov.Chat with exponential backoff on transient errors.
func (r *geminiRunner) retryChat(ctx context.Context, sessionKey string, req provider.ChatRequest) (*provider.ChatResponse, error) {
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

func (r *geminiRunner) waitBeforeRetry(ctx context.Context, lastErr error, attempt int, delay *time.Duration, maxDelay time.Duration) error {
	slog.Warn("runner: transient error, retrying", "attempt", attempt, "delay", *delay, "err", lastErr)
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(*delay):
	}
	*delay *= 2
	if *delay > maxDelay {
		*delay = maxDelay
	}
	return nil
}

func (r *geminiRunner) attemptChat(ctx context.Context, sessionKey string, attempt int, req provider.ChatRequest) (*provider.ChatResponse, error) {
	// Rate-limit: acquire a token before each attempt.
	if waitErr := r.limiter.Wait(ctx); waitErr != nil {
		return nil, waitErr
	}

	var resp *provider.ChatResponse
	fn := func(ctx context.Context) error {
		return r.breaker.Execute(func() error {
			var callErr error
			resp, callErr = r.prov.Chat(ctx, req)
			return callErr
		})
	}

	var err error
	if r.tracer != nil {
		err = r.tracer.TraceGeminiCall(ctx, sessionKey, attempt, fn)
	} else {
		err = fn(ctx)
	}

	if err == nil {
		// Record token consumption if tracer is present.
		if r.tracer != nil && resp != nil && resp.Usage.TotalTokens > 0 {
			r.tracer.RecordTokens(ctx, int64(resp.Usage.TotalTokens))
		}
		return resp, nil
	}
	return nil, err
}

func (r *geminiRunner) shouldRetry(err error) bool {
	// Circuit open: fail immediately without retrying.
	if errors.Is(err, resilience.ErrCircuitOpen) {
		return false
	}
	return bot.IsTransientError(err)
}

// extractText joins all non-empty text parts from a StrategicMessage.
func extractText(msg agentctx.StrategicMessage) string {
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

// lastUserText returns the text of the last user message in messages, or "".
func lastUserText(messages []agentctx.StrategicMessage) string {
	for i := len(messages) - 1; i >= 0; i-- {
		if messages[i].Role == agentctx.RoleUser && messages[i].Content != nil && messages[i].Content.Str != nil {
			return *messages[i].Content.Str
		}
	}
	return ""
}

// buildCorrectionMessage formats a critic report's required corrections into a
// user-facing correction instruction that the agent can act on.
func buildCorrectionMessage(report map[string]any) string {
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

// truncateToolResult cuts off oversized tool outputs at maxBytes.
// Zero or negative maxBytes means no truncation (disabled).
func truncateToolResult(result string, maxBytes int) string {
	if maxBytes <= 0 || len(result) <= maxBytes {
		return result
	}

	// F-076 Review: slog truncation event.
	slog.Info("runner: tool result truncated", "max_bytes", maxBytes, "original_size", len(result))

	// F-076: Truncate at maxBytes while ensuring we don't break multi-byte UTF-8 sequences.
	// We walk backwards from maxBytes to find the start of the last rune.
	idx := maxBytes
	for idx > 0 && !utf8.RuneStart(result[idx]) {
		idx--
	}

	const truncationNotice = "\n\n[... truncated: result exceeded %d bytes ...]"
	return result[:idx] + fmt.Sprintf(truncationNotice, maxBytes)
}

func cmdSimulate() *cobra.Command {
	return &cobra.Command{
		Use:   "simulate <prompt>",
		Short: "Simulate a user message locally",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			prompt := args[0]
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config: %w", err)
			}

			// Pre-flight diagnostics — mirrors gobot strategic_launcher.py
			if err := doctor.Run(cfg, nil); err != nil {
				slog.Warn("pre-flight diagnostics found issues", "err", err)
			}

			ctx := cmd.Context()
			stack, cleanup, err := buildAgentStack(ctx, cfg)
			if err != nil {
				return err
			}
			defer cleanup()

			runner := stack.runner

			// F-012: create shared Hooks instance
			hooks := &agent.Hooks{}
			// F-063: Automated Handoffs
			hooks.RegisterPostDispatch(agent.NewHandoffHook(cfg.StorageRoot()))

			store, _ := agentctx.GetCheckpointManager(cfg.StorageRoot())
			mgr := stack.NewSessionManager(cfg, store, nil)
			mgr.SetHooks(hooks)
			runner.SetHooks(hooks)

			fmt.Printf("--- Simulating Prompt ---\n%s\n\n", prompt)
			fmt.Println("Waiting for response...")
			reply, err := mgr.Dispatch(ctx, "cli-sim", "cli-user", prompt)
			if err != nil {
				return fmt.Errorf("dispatch: %w", err)
			}

			fmt.Printf("\n--- Agent Response ---\n%s\n", reply)
			return nil
		},
	}
}

type dispatchHandler struct {
	mgr          *agent.SessionManager
	memory       *memory.MemoryStore        // may be nil
	consolidator *consolidator.Consolidator // may be nil
	hitl         *agent.HITLManager         // may be nil
}

func (h *dispatchHandler) Handle(ctx context.Context, sessionKey string, msg bot.InboundMessage) (string, error) {
	if reply, ok := h.maybeHandleAdminCommand(sessionKey, msg.Text); ok {
		return reply, nil
	}

	slog.Debug("handler: dispatching to session manager", "session", sessionKey)
	userID := bot.UserID(msg.ChatID, msg.SenderID)
	reply, err := h.mgr.Dispatch(ctx, sessionKey, userID, msg.Text)
	if err != nil {
		if errors.Is(err, resilience.ErrCircuitOpen) {
			return "I'm sorry, I'm currently having trouble connecting to one of my services. Please try again in a few moments.", nil
		}
		return "", err
	}
	if h.memory != nil {
		h.indexMemory(sessionKey, msg.Text, reply)
	}
	if h.consolidator != nil && reply != "" {
		h.consolidator.ConsolidateAsync(sessionKey, reply)
	}
	return reply, nil
}

func (h *dispatchHandler) maybeHandleAdminCommand(sessionKey, text string) (string, bool) {
	if strings.TrimSpace(text) == "/reset_circuits" {
		resilience.ResetAll()
		slog.Info("resilience: all circuit breakers reset by user", "session", sessionKey)
		return "All circuit breakers have been reset.", true
	}
	return "", false
}

func (h *dispatchHandler) indexMemory(sessionKey, userMsg, assistantReply string) {
	if memory.ShouldSkipRAG(userMsg) {
		return
	}
	ns := "session:" + sessionKey
	_ = h.memory.Index(ns, "USER: "+userMsg)
	if assistantReply != "" {
		if indexErr := h.memory.Index(ns, "ASSISTANT: "+assistantReply); indexErr != nil {
			slog.Warn("memory: index failed", "session", sessionKey, "err", indexErr)
		}
	}
}

func (h *dispatchHandler) HandleCallback(ctx context.Context, cb bot.InboundCallback) error {
	if h.hitl != nil {
		return h.hitl.HandleCallback(ctx, cb)
	}
	return nil
}

// runIdempotencyCleanup runs periodic background cleanup of expired idempotency keys.
// F-069: Periodic cleanup to prevent unbounded SQLite growth.
func runIdempotencyCleanup(ctx context.Context, store *agentctx.IdempotencyStore, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			cleaned, err := store.CleanupExpired(ctx)
			if err != nil {
				slog.Error("run: idempotency cleanup failed", "err", err)
				continue
			}
			if cleaned > 0 {
				slog.Info("run: cleaned up expired idempotency keys", "count", cleaned)
			}
		}
	}
}
