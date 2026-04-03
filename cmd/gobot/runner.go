package main

import (
	"context"
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
	"github.com/allthingscode/gobot/internal/provider"
	"github.com/allthingscode/gobot/internal/resilience"
)

// geminiRunner implements the agent.Runner interface using a provider.Provider.
type geminiRunner struct {
	prov              provider.Provider
	model             string
	systemPrompt      string
	memStore          *memory.MemoryStore // may be nil; used for RAG context injection
	tools             []Tool              // registered tools exposed to the provider
	breaker           *resilience.Breaker // circuit breaker for API calls
	limiter           *rate.Limiter       // token-bucket rate limiter
	hooks             *agent.Hooks        // may be nil; set via SetHooks
	maxToolIterations int
	maxTokens         int
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
		limiter:           rate.NewLimiter(rate.Every(time.Second), 3),
		maxToolIterations: 25,
		maxTokens:         cfg.MaxTokens(),
	}
}

// RunText makes a single-turn LLM call with the given prompt text and returns
// the model's text response. Used by the memory consolidator (F-028).
func (r *geminiRunner) RunText(ctx context.Context, prompt string) (string, error) {
	req := provider.ChatRequest{
		Model:    r.model,
		Messages: []agentctx.StrategicMessage{{Role: "user", Content: &agentctx.MessageContent{Str: &prompt}}},
	}
	resp, err := r.retryChat(ctx, req)
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

	// 2. Prepare Tool Declarations
	var toolDecls []provider.ToolDeclaration
	for _, t := range r.tools {
		toolDecls = append(toolDecls, t.Declaration())
	}

	// toolSeq records the tool names called across all iterations for diagnostics.
	toolSeq := make([]string, 0, r.maxToolIterations*2)

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
		resp, err := r.retryChat(ctx, req)
		if err != nil {
			return "", nil, fmt.Errorf("chat: %w", err)
		}

		// 5. Append Assistant Message
		messages = append(messages, resp.Message)

		// 6. Check for Tool Calls
		if len(resp.Message.ToolCalls) == 0 {
			// Terminal text response
			text := extractText(resp.Message)
			return text, messages, nil
		}

		// 7. Execute Tools
		for _, tc := range resp.Message.ToolCalls {
			name, _ := tc["name"].(string)
			args, _ := tc["args"].(map[string]any)

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
				result, execErr = r.executeTool(ctx, sessionKey, name, args)
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
func (r *geminiRunner) executeTool(ctx context.Context, sessionKey string, name string, args map[string]any) (string, error) {
	for _, t := range r.tools {
		if t.Name() == name {
			return t.Execute(ctx, sessionKey, args)
		}
	}
	return "", fmt.Errorf("unknown tool: %s", name)
}

// retryChat calls prov.Chat with exponential backoff on transient errors.
func (r *geminiRunner) retryChat(ctx context.Context, req provider.ChatRequest) (*provider.ChatResponse, error) {
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
		err := r.breaker.Execute(func() error {
			var callErr error
			resp, callErr = r.prov.Chat(ctx, req)
			return callErr
		})

		if err == nil {
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
