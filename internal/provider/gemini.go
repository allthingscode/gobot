package provider

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log/slog"
	"strings"

	agentctx "github.com/allthingscode/gobot/internal/context"
	"google.golang.org/genai"
)

// GeminiProvider implements the Provider interface for Google's Gemini models.
type GeminiProvider struct {
	client *genai.Client
}

// NewGeminiProvider creates a new GeminiProvider using the provided genai.Client.
func NewGeminiProvider(client *genai.Client) *GeminiProvider {
	return &GeminiProvider{client: client}
}

// Name returns the provider name.
func (p *GeminiProvider) Name() string {
	return "gemini"
}

// Chat executes a single-turn LLM call via the Gemini API.
func (p *GeminiProvider) Chat(ctx context.Context, req ChatRequest) (*ChatResponse, error) {
	contents := p.messagesToContents(req.Messages)
	config := p.buildConfig(req)

	resp, err := p.client.Models.GenerateContent(ctx, req.Model, contents, config)
	if err != nil {
		return nil, err
	}

	if len(resp.Candidates) == 0 || resp.Candidates[0].Content == nil {
		return nil, fmt.Errorf("gemini: no candidates returned")
	}

	candidate := resp.Candidates[0]
	msg := agentctx.StrategicMessage{
		Role: agentctx.RoleAssistant,
	}

	// Extract text content, thinking, and tool calls in order
	var textParts []string
	var lastThoughtSig []byte
	for _, part := range candidate.Content.Parts {
		switch {
		case part.Thought:
			msg.ThinkingBlocks = append(msg.ThinkingBlocks, map[string]any{
				"text":              part.Text,
				"thought_signature": part.ThoughtSignature,
			})
			lastThoughtSig = part.ThoughtSignature
			// reasoningContent is used for display/logging
			if msg.ReasoningContent == nil {
				msg.ReasoningContent = &part.Text
			} else {
				combined := *msg.ReasoningContent + "\n" + part.Text
				msg.ReasoningContent = &combined
			}

		case part.FunctionCall != nil:
			tc := map[string]any{
				"name": part.FunctionCall.Name,
				"args": part.FunctionCall.Args,
			}
			// If this part itself has a signature, or we saw one just before it
			sig := part.ThoughtSignature
			if len(sig) == 0 {
				sig = lastThoughtSig
			}
			if len(sig) > 0 {
				tc["thought_signature"] = sig
			}
			msg.ToolCalls = append(msg.ToolCalls, tc)

		case part.Text != "":
			textParts = append(textParts, part.Text)
		}
	}

	if len(textParts) > 0 {
		text := strings.Join(textParts, "\n")
		msg.Content = &agentctx.MessageContent{Str: &text}
	}

	usage := TokenUsage{}
	if resp.UsageMetadata != nil {
		usage.PromptTokens = int(resp.UsageMetadata.PromptTokenCount)
		usage.CompletionTokens = int(resp.UsageMetadata.CandidatesTokenCount)
		usage.TotalTokens = int(resp.UsageMetadata.TotalTokenCount)
	}

	return &ChatResponse{
		Message: msg,
		Usage:   usage,
	}, nil
}

// Models returns a list of supported Gemini models.
func (p *GeminiProvider) Models() []ModelInfo {
	// Return a static list or fetch from API. For now, static is fine.
	return []ModelInfo{
		{ID: "gemini-3.1-pro-preview", SupportsToolUse: true, SupportsThinking: true},
		{ID: "gemini-3-flash-preview", SupportsToolUse: true, SupportsThinking: true},
		{ID: "gemini-2.0-flash", SupportsToolUse: true, SupportsThinking: true},
		{ID: "gemini-2.0-flash-lite-preview-02-05", SupportsToolUse: true, SupportsThinking: true},
		{ID: "gemini-2.0-pro-exp-02-05", SupportsToolUse: true, SupportsThinking: true},
		{ID: "gemini-1.5-flash", SupportsToolUse: true},
		{ID: "gemini-1.5-pro", SupportsToolUse: true},
	}
}

func (p *GeminiProvider) messagesToContents(messages []agentctx.StrategicMessage) []*genai.Content {
	contents := make([]*genai.Content, 0, len(messages))
	for i, msg := range messages {
		// A message is valid if it has content, tool calls, thinking blocks, or is a tool response (Name set).
		if msg.Content == nil && len(msg.ToolCalls) == 0 && msg.Name == nil && len(msg.ThinkingBlocks) == 0 {
			slog.Debug("gemini: skipping empty message", "index", i, "role", string(msg.Role))
			continue
		}
		role := string(msg.Role)
		switch msg.Role {
		case agentctx.RoleAssistant:
			role = string(agentctx.RoleModel)
		case agentctx.RoleTool:
			role = string(agentctx.RoleUser)
		}
		c := &genai.Content{Role: role}

		// Handle thinking blocks (must come before text/tool calls in the same message)
		for _, tb := range msg.ThinkingBlocks {
			text, _ := tb["text"].(string)
			sig, _ := tb["thought_signature"].([]byte)
			c.Parts = append(c.Parts, &genai.Part{
				Text:             text,
				Thought:          true,
				ThoughtSignature: sig,
			})
		}

		// Handle text content
		if msg.Content != nil {
			if msg.Content.Str != nil && *msg.Content.Str != "" {
				c.Parts = append(c.Parts, &genai.Part{Text: *msg.Content.Str})
			} else {
				for _, item := range msg.Content.Items {
					if item.Text != nil && item.Text.Text != "" {
						c.Parts = append(c.Parts, &genai.Part{Text: item.Text.Text})
					}
				}
			}
		}

		// Handle tool calls (assistant turn)
		for _, tc := range msg.ToolCalls {
			name, _ := tc["name"].(string)
			args, _ := tc["args"].(map[string]any)

			var sig []byte
			if rawSig, ok := tc["thought_signature"]; ok {
				switch v := rawSig.(type) {
				case []byte:
					sig = v
				case string:
					// In JSON, []byte is base64 encoded string
					sig, _ = base64.StdEncoding.DecodeString(v)
				}
			}

			if name != "" {
				c.Parts = append(c.Parts, &genai.Part{
					FunctionCall: &genai.FunctionCall{
						Name: name,
						Args: args,
					},
					ThoughtSignature: sig,
				})
			}
		}

		// Handle tool results (user turn)
		if msg.Role == agentctx.RoleTool || (msg.Role == agentctx.RoleUser && msg.ToolCallID != nil) {
			if msg.Name != nil && msg.Content != nil && msg.Content.Str != nil {
				var res map[string]any
				if err := json.Unmarshal([]byte(*msg.Content.Str), &res); err != nil {
					res = map[string]any{"output": *msg.Content.Str}
				}
				c.Parts = append(c.Parts, genai.NewPartFromFunctionResponse(*msg.Name, res))
			}
		}

		// Final safety check: if we somehow ended up with no parts, don't add the content.
		if len(c.Parts) > 0 {
			contents = append(contents, c)
		} else {
			slog.Debug("gemini: message yielded no parts, omitting", "index", i, "role", string(msg.Role))
		}
	}
	return contents
}

func (p *GeminiProvider) buildConfig(req ChatRequest) *genai.GenerateContentConfig {
	cfg := &genai.GenerateContentConfig{}

	if req.SystemInstruction != "" {
		cfg.SystemInstruction = &genai.Content{
			Parts: []*genai.Part{{Text: req.SystemInstruction}},
		}
	}

	if req.MaxTokens > 0 {
		cfg.MaxOutputTokens = int32(req.MaxTokens) // #nosec G115 - MaxTokens is bounded by application limits
	}

	if req.Temperature > 0 {
		cfg.Temperature = &req.Temperature
	}

	if len(req.Tools) > 0 {
		decls := make([]*genai.FunctionDeclaration, len(req.Tools))
		for i, t := range req.Tools {
			decls[i] = &genai.FunctionDeclaration{
				Name:        t.Name,
				Description: t.Description,
			}
			if t.Parameters != nil {
				// Convert map[string]any to genai.Schema
				// A simple trick is to marshal/unmarshal
				data, _ := json.Marshal(t.Parameters)
				var schema genai.Schema
				_ = json.Unmarshal(data, &schema)
				decls[i].Parameters = &schema

				// Fix: genai.Schema.Type is an enum (uppercase), but JSON schema usually lowercase
				p.fixSchemaTypes(&schema)
			}
		}
		cfg.Tools = []*genai.Tool{{FunctionDeclarations: decls}}
	}

	return cfg
}

func (p *GeminiProvider) fixSchemaTypes(s *genai.Schema) {
	if s == nil {
		return
	}
	// Convert lowercase type to uppercase for genai.Type enum
	t := string(s.Type)
	if t != "" {
		s.Type = genai.Type(strings.ToUpper(t))
	}
	for _, prop := range s.Properties {
		p.fixSchemaTypes(prop)
	}
	if s.Items != nil {
		p.fixSchemaTypes(s.Items)
	}
}
