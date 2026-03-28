package main

import (
	"context"
	"fmt"
	"log/slog"
	"strings"

	"google.golang.org/genai"
	agentctx "github.com/allthingscode/gobot/internal/context"
)

type geminiRunner struct {
	client       *genai.Client
	model        string
	systemPrompt string
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

	cfg := &genai.GenerateContentConfig{
		Tools: []*genai.Tool{{GoogleSearch: &genai.GoogleSearch{}}},
	}
	if r.systemPrompt != "" {
		cfg.SystemInstruction = &genai.Content{
			Parts: []*genai.Part{{Text: r.systemPrompt}},
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
