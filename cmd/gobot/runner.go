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

	"golang.org/x/time/rate"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/memory"
	"github.com/allthingscode/gobot/internal/observability"
	"github.com/allthingscode/gobot/internal/provider"
	"github.com/allthingscode/gobot/internal/reflection"
	"github.com/allthingscode/gobot/internal/resilience"
)

// geminiRunner implements the agent.Runner interface using a provider.Provider.
type geminiRunner struct {
	prov                provider.Provider
	model               string
	systemPrompt        string
	memStore            *memory.MemoryStore             // may be nil; used for RAG context injection
	tools               []Tool                          // registered tools exposed to the provider
	breaker             *resilience.Breaker             // circuit breaker for API calls
	limiter             *rate.Limiter                   // token-bucket rate limiter
	hooks               *agent.Hooks                    // may be nil; set via SetHooks
	tracer              *observability.DispatchTracer
	idempStore          *agentctx.IdempotencyStore      // may be nil; idempotency for side-effecting tools
	maxToolIterations   int
	maxTokens           int
	enableReflection    bool // opt-in; off by default for cost control
	maxReflectionRounds int  // default 1 → ≤2x token overhead
}

// newGeminiRunner creates a new geminiRunner for the given provider and model.
func newGeminiRunner(prov provider.Provider, model string, systemPrompt string, cfg *config.Config) *geminiRunner {
	maxFail, window, timeout := cfg.Breaker(prov.Name())
	return &geminiRunner{
		prov:         prov,
		model:        model,
		systemPrompt: systemPrompt,
		// Configured circuit breaker for LLM provider.
		breaker: resilience.New(prov.Name(), maxFail, window, timeout),
		// 3 requests/second burst; conservative default.
		limiter:             rate.NewLimiter(rate.Every(time.Second), 3),
		maxToolIterations:   25,
		maxTokens:           cfg.MaxTokens(),
		enableReflection:    false,
		maxReflectionRounds: 1,
	}
}

// RunText performs a single-turn, text-only LLM call without tool use.
func (r *geminiRunner) RunText(ctx context.Context, sessionKey, prompt string, modelOverride string) (string, error) {
	model := r.model
	if modelOverride != "" {
		model = modelOverride
	}
	req := provider.ChatRequest{
		Model:    model,
		Messages: []agentctx.StrategicMessage{{Role: "user", Content: &agentctx.MessageContent{Str: &prompt}}},
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

// Run executes the tool-call/response loop until the provider returns a terminal text response.
//
// Each iteration:
//  1. Calls prov.Chat with the current messages and system prompt (including RAG).
//  2. If the response contains ToolCalls, dispatches each to the matching Tool.Execute,
//     appends the results as new "tool" messages, and loops.
//  3. If the response contains no tool calls, extracts the text and returns.
//
// Returns an error if maxToolIterations is exceeded or prov.Chat fails.
func (r *geminiRunner) Run(ctx context.Context, sessionKey string, messages []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error) {
	// 1. Build System Prompt with RAG and Hooks
	sysPrompt := r.systemPrompt
	if r.memStore != nil {
		if userText := lastUserText(messages); !memory.ShouldSkipRAG(userText) {
			if results, _ := r.memStore.Search(userText, 5); len(results) > 0 {
				filtered := memory.FilterRAGResults(results, 0.0)
				if block, n := memory.FormatRAGBlock(filtered); n > 0 {
					slog.Debug("runner: injecting RAG context", "entries", n)
					if sysPrompt != "" {
						sysPrompt = block + "\n\n" + sysPrompt
					} else {
						sysPrompt = block
					}
				}
			}
		}
	}

	if r.hooks != nil {
		sysPrompt = r.hooks.RunPrePrompt(ctx, sysPrompt)
	}

	// Planning phase (F-049): generate a validation rubric before executing.
	var rubric map[string]any
	userText := lastUserText(messages)
	if r.enableReflection && userText != "" {
		planPrompt := reflection.GenerateRubricPrompt(userText)
		if planStr, planErr := r.RunText(ctx, sessionKey, planPrompt, ""); planErr == nil {
			if parsed, ok := reflection.ParseJSONResponse(planStr); ok {
				rubric = parsed
				slog.Debug("runner: planning rubric generated", "session", sessionKey)
			}
		}
	}

	// 2. Prepare Tool Declarations
	var toolDecls []provider.ToolDeclaration
	for _, t := range r.tools {
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
			// Terminal text response
			text := extractText(resp.Message)

			// Reflection phase (F-049): audit the terminal response against the rubric.
			if r.enableReflection && rubric != nil && reflectionRounds < r.maxReflectionRounds {
				criticPrompt := reflection.GenerateCriticPrompt(userText, rubric, text)
				if criticStr, criticErr := r.RunText(ctx, sessionKey, criticPrompt, ""); criticErr == nil {
					if report, ok := reflection.ParseJSONResponse(criticStr); ok {
						score := reflection.CalculateTotalScore(report, rubric)
						threshold := 0.7
						if t, ok := rubric["success_threshold"].(float64); ok {
							threshold = t
						}
						if score < threshold {
							reflectionRounds++
							correction := buildCorrectionMessage(report)
							messages = append(messages, agentctx.StrategicMessage{
								Role:    "user",
								Content: &agentctx.MessageContent{Str: &correction},
							})
							slog.Info("runner: reflection backtrack triggered",
								"session", sessionKey,
								"score", score,
								"threshold", threshold,
								"round", reflectionRounds,
							)
							continue
						}
						slog.Debug("runner: reflection passed", "session", sessionKey, "score", score)
					}
				}
			}

			return text, messages, nil
		}

		// 7. Execute Tools
		for _, tc := range resp.Message.ToolCalls {
			name, ok := tc["name"].(string)
			if !ok {
				return "", nil, fmt.Errorf("malformed tool call: missing or non-string 'name' field: %v", tc)
			}
			args, ok := tc["args"].(map[string]any)
			if !ok {
				return "", nil, fmt.Errorf("malformed tool call: missing or non-map 'args' field for tool %s: %v", name, tc)
			}

			// Some providers might not provide an ID, but internal/context expects it if available.
			var toolCallID *string
			if id, ok := tc["id"].(string); ok {
				toolCallID = &id
			}

			toolSeq = append(toolSeq, name)
			slog.Info("runner: tool call", "session", sessionKey, "tool", name, "args", args, "iter", iter)

			var result string
			var execErr error
			var skipExec bool

			// Run PreTool hooks (F-048) -- allow interception/approval.
			if r.hooks != nil {
				override, err := r.hooks.RunPreTool(ctx, sessionKey, name, args)
				if err != nil {
					execErr = err
				} else if override != "" {
					result = override
					skipExec = true
					slog.Debug("runner: tool pre-hook override", "tool", name, "result", result)
				}
			}

			if execErr == nil && !skipExec {
				// Generate a deterministic idempotency key based on the tool's position in the sequence and parameters.
				// This ensures that if the agent loop crashes and resumes, the exact same tool call gets the same key,
				// preventing duplicate real-world side effects.
				paramsHash, hashErr := agentctx.HashParams(args)
				if hashErr != nil {
					slog.Warn("runner: failed to hash tool params, skipping idempotency check", "tool", name, "err", hashErr)
					result, execErr = r.executeTool(ctx, sessionKey, "", name, args, "")
				} else {
					idemKey := fmt.Sprintf("%s-%d-%d-%s-%s", sessionKey, iter, len(toolSeq), name, paramsHash)
					result, execErr = r.executeTool(ctx, sessionKey, idemKey, name, args, paramsHash)
				}
				if execErr == nil {
					slog.Info("runner: tool result", "tool", name, "result_len", len(result))
					slog.Debug("runner: tool result detail", "tool", name, "result", result)
				}
			}

			if execErr != nil {
				slog.Error("runner: tool execution failed", "session", sessionKey, "tool", name, "err", execErr)
				result = fmt.Sprintf("Error: %v", execErr)
			} else {
				// Run PostTool hooks (F-012) -- transform tool results before returning to agent.
				if r.hooks != nil && !skipExec {
					result = r.hooks.RunPostTool(ctx, name, result)
				}
			}

			// Append result as a new message
			messages = append(messages, agentctx.StrategicMessage{
				Role:       "tool",
				Name:       &name,
				Content:    &agentctx.MessageContent{Str: &result},
				ToolCallID: toolCallID,
			})
		}
	}

	slog.Error("runner: tool loop exhausted",
		"session", sessionKey,
		"iterations", r.maxToolIterations,
		"tool_sequence", strings.Join(toolSeq, " -> "),
	)
	return "", nil, fmt.Errorf("runner: tool dispatch loop exceeded %d iterations", r.maxToolIterations)
}

// executeTool dispatches a tool call to the matching registered Tool.
// For side-effecting tools, it checks the idempotency store before execution
// and caches the result to prevent duplicates on retry.
func (r *geminiRunner) executeTool(ctx context.Context, sessionKey string, idemKey string, name string, args map[string]any, paramsHash string) (string, error) {
	// Check if this is a side-effecting tool that needs idempotency protection.
	if isSideEffectingTool(name) && r.idempStore != nil {
		// If paramsHash not already computed by caller, compute it now.
		if paramsHash == "" {
			var err error
			paramsHash, err = agentctx.HashParams(args)
			if err != nil {
				return "", fmt.Errorf("executeTool: hash params: %w", err)
			}
		}

		// Check idempotency store.
		checkResult, err := r.idempStore.Check(idemKey, name, paramsHash)
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
		result, execErr := r.executeToolInner(ctx, sessionKey, name, args)
		if execErr == nil {
			// Store result in idempotency cache.
			if storeErr := r.idempStore.Store(idemKey, name, paramsHash, result, sessionKey); storeErr != nil {
				slog.Warn("executeTool: failed to store idempotency key", "err", storeErr)
			}
		}
		return result, execErr
	}

	// Non-side-effecting tool or no idempotency store — execute normally.
	return r.executeToolInner(ctx, sessionKey, name, args)
}

// executeToolInner is the inner implementation of executeTool without idempotency checks.
func (r *geminiRunner) executeToolInner(ctx context.Context, sessionKey string, name string, args map[string]any) (string, error) {
	for _, t := range r.tools {
		if t.Name() == name {
			if r.tracer != nil {
				return r.tracer.TraceToolExecution(ctx, sessionKey, name, func(ctx context.Context) (string, error) {
					return t.Execute(ctx, sessionKey, args)
				})
			}
			return t.Execute(ctx, sessionKey, args)
		}
	}
	return "", fmt.Errorf("unknown tool: %s", name)
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

// retryChat calls prov.Chat with exponential backoff on transient errors.
func (r *geminiRunner) retryChat(ctx context.Context, sessionKey string, req provider.ChatRequest) (*provider.ChatResponse, error) {
	const maxGenRetries = 3
	const initialDelay = 1 * time.Second
	const maxDelay = 30 * time.Second

	delay := initialDelay
	var lastErr error
	for attempt := 0; attempt <= maxGenRetries; attempt++ {
		if attempt > 0 {
			slog.Warn("runner: transient error, retrying", "attempt", attempt, "delay", delay, "err", lastErr)
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-time.After(delay):
			}
			delay *= 2
			if delay > maxDelay {
				delay = maxDelay
			}
		}

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

		// Circuit open: fail immediately without retrying.
		if errors.Is(err, resilience.ErrCircuitOpen) {
			return nil, err
		}
		if !bot.IsTransientError(err) {
			return nil, err
		}
		lastErr = err
	}
	return nil, fmt.Errorf("%d retries exhausted: %w", maxGenRetries, lastErr)
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
		if messages[i].Role == "user" && messages[i].Content != nil && messages[i].Content.Str != nil {
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
				sb.WriteString(fmt.Sprintf("%d. %s\n", i+1, s))
			}
		}
	}
	sb.WriteString("Please revise your response to address the above.")
	return sb.String()
}
