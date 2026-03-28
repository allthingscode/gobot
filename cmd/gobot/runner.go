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

type geminiRunner struct {
	client       *genai.Client
	model        string
	systemPrompt string
	memStore     *memory.MemoryStore // may be nil; used for RAG context injection
}

func newGeminiRunner(client *genai.Client, model string, systemPrompt string) *geminiRunner {
	return &geminiRunner{client: client, model: model, systemPrompt: systemPrompt}
}

// Run converts []StrategicMessage to []*genai.Content, calls GenerateContent,
// extracts text, appends assistant turn, returns (text, updatedMessages, error).
//
// Conversion:
//   - Role "user" → Content.Role = "user"
//   - Role "assistant" → Content.Role = "model"
//   - Content.Str != nil → single Part{Text: *Str}
//   - Content.Items → Part{Text} for each item where item.Text != nil
//   - Skip messages where Content is nil
//
// Text extraction: join Part.Text values from Candidates[0].Content.Parts with "\n".
// If len(Candidates) == 0: return error "gemini: no candidates returned".
// Append new StrategicMessage{Role:"assistant", Content:&agentctx.MessageContent{Str:&text}}.
func (r *geminiRunner) Run(ctx context.Context, sessionKey string, messages []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error) {
	var contents []*genai.Content
	for _, msg := range messages {
		if msg.Content == nil {
			continue
		}
		role := msg.Role
		if role == "assistant" {
			role = "model"
		}
		c := &genai.Content{
			Role: role,
		}
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

	// RAG: inject relevant historical context from long-term memory.
	systemPrompt := r.systemPrompt
	if r.memStore != nil {
		if userText := lastUserText(messages); !memory.ShouldSkipRAG(userText) {
			if results, _ := r.memStore.Search(userText, 5); len(results) > 0 {
				filtered := memory.FilterRAGResults(results, 0.0)
				if block, n := memory.FormatRAGBlock(filtered); n > 0 {
					slog.Debug("gemini: injecting RAG context", "session", sessionKey, "entries", n)
					if systemPrompt != "" {
						systemPrompt = block + "\n\n" + systemPrompt
					} else {
						systemPrompt = block
					}
				}
			}
		}
	}

	cfg := &genai.GenerateContentConfig{
		Tools: []*genai.Tool{{GoogleSearch: &genai.GoogleSearch{}}},
	}
	if systemPrompt != "" {
		cfg.SystemInstruction = &genai.Content{
			Parts: []*genai.Part{{Text: systemPrompt}},
		}
	}
	slog.Debug("gemini: calling GenerateContent", "session", sessionKey, "model", r.model, "messages", len(contents))
	resp, err := r.client.Models.GenerateContent(ctx, r.model, contents, cfg)
	if err != nil {
		return "", nil, fmt.Errorf("gemini generate: %w", err)
	}
	slog.Debug("gemini: GenerateContent returned", "session", sessionKey, "candidates", len(resp.Candidates))

	if len(resp.Candidates) == 0 || resp.Candidates[0].Content == nil {
		return "", nil, fmt.Errorf("gemini: no candidates returned")
	}

	var parts []string
	for _, p := range resp.Candidates[0].Content.Parts {
		parts = append(parts, p.Text)
	}
	text := strings.Join(parts, "\n")

	newMsg := agentctx.StrategicMessage{
		Role: "assistant",
		Content: &agentctx.MessageContent{
			Str: &text,
		},
	}
	updatedMessages := append(messages, newMsg)

	return text, updatedMessages, nil
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
