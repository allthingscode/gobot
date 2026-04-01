package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"golang.org/x/time/rate"
	"google.golang.org/genai"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/bot"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/memory"
	"github.com/allthingscode/gobot/internal/resilience"
)

// maxToolIterations caps the tool-call/response loop within a single Run call.
// Prevents infinite loops when the model keeps requesting tools.

type geminiRunner struct {
	client            *genai.Client
	model             string
	systemPrompt      string
	memStore          *memory.MemoryStore // may be nil; used for RAG context injection
	tools             []Tool              // registered tools exposed to Gemini as FunctionDeclarations
	breaker           *resilience.Breaker // circuit breaker for Gemini API calls
	limiter           *rate.Limiter       // token-bucket rate limiter for Gemini API calls
	hooks             *agent.Hooks        // may be nil; set via SetHooks
	maxToolIterations int
	maxTokens         int
}

func newGeminiRunner(client *genai.Client, model string, systemPrompt string, maxIter int, maxTokens int) *geminiRunner {
	return &geminiRunner{
		client:       client,
		model:        model,
		systemPrompt: systemPrompt,
		// Trip after 5 consecutive failures within 60s; attempt recovery after 300s.
		breaker: resilience.New("gemini", 5, 60*time.Second, 300*time.Second),
		// 3 requests/second burst; conservative default for shared Gemini quota.
		limiter:           rate.NewLimiter(rate.Every(time.Second), 3),
		maxToolIterations: maxIter,
		maxTokens:         maxTokens,
	}
}

// RunText makes a single-turn LLM call with the given prompt text and returns
// the model's text response. Used by the memory consolidator (F-028).
func (r *geminiRunner) RunText(ctx context.Context, prompt string) (string, error) {
	contents := []*genai.Content{
		{Parts: []*genai.Part{{Text: prompt}}, Role: "user"},
	}
	resp, err := r.client.Models.GenerateContent(ctx, r.model, contents, nil)
	if err != nil {
		return "", fmt.Errorf("RunText: %w", err)
	}
	if len(resp.Candidates) == 0 || resp.Candidates[0].Content == nil {
		return "", nil
	}
	var sb strings.Builder
	for _, part := range resp.Candidates[0].Content.Parts {
		if part.Text != "" {
			sb.WriteString(part.Text)
		}
	}
	return sb.String(), nil
}

// SetHooks configures lifecycle hooks for this runner.
// PrePrompt hooks are applied in buildConfig before each Gemini call.
func (r *geminiRunner) SetHooks(h *agent.Hooks) {
	r.hooks = h
}

// Run converts []StrategicMessage to []*genai.Content, then drives a
// tool-call/response loop until Gemini returns a terminal text response.
//
// Each iteration:
//  1. Calls GenerateContent with the current contents.
//  2. If the response contains FunctionCall parts, dispatches each to the
//     matching Tool.Execute, appends the FunctionResponse, and loops.
//  3. If the response contains only text parts, extracts the text, appends
//     a new assistant StrategicMessage, and returns.
//
// Returns an error if maxToolIterations is exceeded or GenerateContent fails.
func (r *geminiRunner) Run(ctx context.Context, sessionKey string, messages []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error) {
	contents := r.messagesToContents(messages)
	cfg := r.buildConfig(messages)

	// toolSeq records the tool names called across all iterations for diagnostics.
	toolSeq := make([]string, 0, r.maxToolIterations*2)

	for iter := 0; iter < r.maxToolIterations; iter++ {
		slog.Debug("gemini: calling GenerateContent", "session", sessionKey, "model", r.model, "messages", len(contents), "iter", iter)
		resp, err := r.retryGenerateContent(ctx, contents, cfg)
		if err != nil {
			return "", nil, fmt.Errorf("gemini generate: %w", err)
		}
		if len(resp.Candidates) == 0 || resp.Candidates[0].Content == nil {
			return "", nil, fmt.Errorf("gemini: no candidates returned")
		}
		slog.Debug("gemini: GenerateContent returned", "session", sessionKey, "candidates", len(resp.Candidates))

		funcCalls := resp.FunctionCalls()
		if len(funcCalls) == 0 {
			// Terminal response -- extract text and return.
			text := extractResponseText(resp)
			newMsg := agentctx.StrategicMessage{
				Role:    "assistant",
				Content: &agentctx.MessageContent{Str: &text},
			}
			return text, append(messages, newMsg), nil
		}

		// Append the model's function-call turn to contents.
		contents = append(contents, resp.Candidates[0].Content)

		// Execute each function call and collect FunctionResponse parts.
		responseParts := make([]*genai.Part, 0, len(funcCalls))
		for _, fc := range funcCalls {
			toolSeq = append(toolSeq, fc.Name)
			slog.Info("gemini: tool call", "session", sessionKey, "tool", fc.Name, "iter", iter)

			var result string
			var execErr error
			var skipExec bool

			// Run PreTool hooks (F-048) -- allow interception/approval.
			if r.hooks != nil {
				override, err := r.hooks.RunPreTool(ctx, sessionKey, fc.Name, fc.Args)
				if err != nil {
					execErr = err
				} else if override != "" {
					result = override
					skipExec = true
				}
			}

			if execErr == nil && !skipExec {
				result, execErr = r.executeTool(ctx, sessionKey, fc)
			}

			var response map[string]any
			if execErr != nil {
				slog.Warn("gemini: tool execution failed", "tool", fc.Name, "err", execErr)
				response = map[string]any{"error": execErr.Error()}
			} else {
				// Run PostTool hooks (F-012) -- transform tool results before returning to agent.
				if r.hooks != nil && !skipExec {
					result = r.hooks.RunPostTool(ctx, fc.Name, result)
				}
				response = map[string]any{"output": result}
			}
			responseParts = append(responseParts, genai.NewPartFromFunctionResponse(fc.Name, response))
		}
		// Function responses are sent back in a "user" turn.
		contents = append(contents, &genai.Content{
			Role:  "user",
			Parts: responseParts,
		})
	}

	slog.Error("gemini: tool loop exhausted",
		"session", sessionKey,
		"iterations", r.maxToolIterations,
		"tool_sequence", strings.Join(toolSeq, " -> "),
	)
	return "", nil, fmt.Errorf("gemini: tool dispatch loop exceeded %d iterations", r.maxToolIterations)
}

// executeTool dispatches a FunctionCall to the matching registered Tool.
// Returns an error if no tool with fc.Name is registered.
func (r *geminiRunner) executeTool(ctx context.Context, sessionKey string, fc *genai.FunctionCall) (string, error) {
	for _, t := range r.tools {
		if t.Name() == fc.Name {
			return t.Execute(ctx, sessionKey, fc.Args)
		}
	}
	return "", fmt.Errorf("unknown tool: %s", fc.Name)
}

// retryGenerateContent calls GenerateContent with exponential backoff on transient errors.
// Makes up to maxGenRetries additional attempts after the first failure; initial delay 1s,
// doubling each retry, capped at 30s. Non-transient errors are returned immediately.
func (r *geminiRunner) retryGenerateContent(ctx context.Context, contents []*genai.Content, cfg *genai.GenerateContentConfig) (*genai.GenerateContentResponse, error) {
	const maxGenRetries = 3
	const initialDelay = 1 * time.Second
	const maxDelay = 30 * time.Second

	delay := initialDelay
	var lastErr error
	for attempt := 0; attempt <= maxGenRetries; attempt++ {
		if attempt > 0 {
			slog.Warn("gemini: transient error, retrying", "attempt", attempt, "delay", delay, "err", lastErr)
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

		var resp *genai.GenerateContentResponse
		err := r.breaker.Execute(func() error {
			var callErr error
			resp, callErr = r.client.Models.GenerateContent(ctx, r.model, contents, cfg)
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

// buildConfig assembles the GenerateContentConfig for a Run call.
// It applies RAG context injection (if memStore is set) and adds all
// registered tool declarations alongside the Google Search grounding tool.
func (r *geminiRunner) buildConfig(messages []agentctx.StrategicMessage) *genai.GenerateContentConfig {
	// RAG: inject relevant historical context into system prompt.
	systemPrompt := r.systemPrompt
	if r.memStore != nil {
		if userText := lastUserText(messages); !memory.ShouldSkipRAG(userText) {
			if results, _ := r.memStore.Search(userText, 5); len(results) > 0 {
				filtered := memory.FilterRAGResults(results, 0.0)
				if block, n := memory.FormatRAGBlock(filtered); n > 0 {
					slog.Debug("gemini: injecting RAG context", "entries", n)
					if systemPrompt != "" {
						systemPrompt = block + "\n\n" + systemPrompt
					} else {
						systemPrompt = block
					}
				}
			}
		}
	}

	// Build tool list. We cannot mix GoogleSearch with FunctionDeclarations
	// without 'include_server_side_tool_invocations' config (which the SDK lacks).
	var tools []*genai.Tool
	if len(r.tools) > 0 {
		decls := make([]*genai.FunctionDeclaration, len(r.tools))
		for i, t := range r.tools {
			decls[i] = t.Declaration()
		}
		tools = append(tools, &genai.Tool{FunctionDeclarations: decls})
	} else {
		// Only use Grounding if no custom tools are present.
		tools = append(tools, &genai.Tool{GoogleSearch: &genai.GoogleSearch{}})
	}

	// Run PrePrompt hooks (F-012) -- allow features to inject into system prompt.
	if r.hooks != nil {
		systemPrompt = r.hooks.RunPrePrompt(context.Background(), systemPrompt)
	}

	cfg := &genai.GenerateContentConfig{Tools: tools}
	if r.maxTokens > 0 {
		cfg.MaxOutputTokens = int32(r.maxTokens)
	}
	if systemPrompt != "" {
		cfg.SystemInstruction = &genai.Content{
			Parts: []*genai.Part{{Text: systemPrompt}},
		}
	}
	return cfg
}

// messagesToContents converts []StrategicMessage to the []*genai.Content
// format expected by the Gemini API.
func (r *geminiRunner) messagesToContents(messages []agentctx.StrategicMessage) []*genai.Content {
	contents := make([]*genai.Content, 0, len(messages))
	for _, msg := range messages {
		if msg.Content == nil {
			continue
		}
		role := msg.Role
		if role == "assistant" {
			role = "model"
		}
		c := &genai.Content{Role: role}
		if msg.Content.Str != nil {
			c.Parts = append(c.Parts, &genai.Part{Text: *msg.Content.Str})
		} else {
			for _, item := range msg.Content.Items {
				if item.Text != nil {
					c.Parts = append(c.Parts, &genai.Part{Text: item.Text.Text})
				}
			}
		}
		contents = append(contents, c)
	}
	return contents
}

// extractResponseText joins all non-empty text parts from the first candidate.
func extractResponseText(resp *genai.GenerateContentResponse) string {
	var parts []string
	for _, p := range resp.Candidates[0].Content.Parts {
		if p.Text != "" {
			parts = append(parts, p.Text)
		}
	}
	return strings.Join(parts, "\n")
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
