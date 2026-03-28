package main

import (
	"context"
	"fmt"
	"log/slog"
	"strings"

	"google.golang.org/genai"

	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/memory"
)

// maxToolIterations caps the tool-call/response loop within a single Run call.
// Prevents infinite loops when the model keeps requesting tools.
const maxToolIterations = 10

type geminiRunner struct {
	client       *genai.Client
	model        string
	systemPrompt string
	memStore     *memory.MemoryStore // may be nil; used for RAG context injection
	tools        []Tool              // registered tools exposed to Gemini as FunctionDeclarations
}

func newGeminiRunner(client *genai.Client, model string, systemPrompt string) *geminiRunner {
	return &geminiRunner{client: client, model: model, systemPrompt: systemPrompt}
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

	for iter := 0; iter < maxToolIterations; iter++ {
		slog.Debug("gemini: calling GenerateContent", "session", sessionKey, "model", r.model, "messages", len(contents), "iter", iter)
		resp, err := r.client.Models.GenerateContent(ctx, r.model, contents, cfg)
		if err != nil {
			return "", nil, fmt.Errorf("gemini generate: %w", err)
		}
		if len(resp.Candidates) == 0 || resp.Candidates[0].Content == nil {
			return "", nil, fmt.Errorf("gemini: no candidates returned")
		}
		slog.Debug("gemini: GenerateContent returned", "session", sessionKey, "candidates", len(resp.Candidates))

		funcCalls := resp.FunctionCalls()
		if len(funcCalls) == 0 {
			// Terminal response — extract text and return.
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
			slog.Info("gemini: tool call", "session", sessionKey, "tool", fc.Name, "iter", iter)
			result, execErr := r.executeTool(ctx, sessionKey, fc)
			var response map[string]any
			if execErr != nil {
				slog.Warn("gemini: tool execution failed", "tool", fc.Name, "err", execErr)
				response = map[string]any{"error": execErr.Error()}
			} else {
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

	return "", nil, fmt.Errorf("gemini: tool dispatch loop exceeded %d iterations", maxToolIterations)
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

	// Build tool list: Google Search grounding + registered function tools.
	tools := []*genai.Tool{{GoogleSearch: &genai.GoogleSearch{}}}
	if len(r.tools) > 0 {
		decls := make([]*genai.FunctionDeclaration, len(r.tools))
		for i, t := range r.tools {
			decls[i] = t.Declaration()
		}
		tools = append(tools, &genai.Tool{FunctionDeclarations: decls})
	}

	cfg := &genai.GenerateContentConfig{Tools: tools}
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
