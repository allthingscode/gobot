package provider

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"google.golang.org/genai"
	agentctx "github.com/allthingscode/gobot/internal/context"
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
		Role: "assistant",
	}

	// Extract text content
	var textParts []string
	for _, part := range candidate.Content.Parts {
		if part.Text != "" {
			textParts = append(textParts, part.Text)
		}
	}
	if len(textParts) > 0 {
		text := strings.Join(textParts, "\n")
		msg.Content = &agentctx.MessageContent{Str: &text}
	}

	// Extract tool calls
	funcCalls := resp.FunctionCalls()
	if len(funcCalls) > 0 {
		msg.ToolCalls = make([]map[string]any, len(funcCalls))
		for i, fc := range funcCalls {
			msg.ToolCalls[i] = map[string]any{
				"name": fc.Name,
				"args": fc.Args,
			}
		}
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
		{ID: "gemini-2.0-flash", SupportsToolUse: true},
		{ID: "gemini-2.0-flash-lite-preview-02-05", SupportsToolUse: true},
		{ID: "gemini-2.0-pro-exp-02-05", SupportsToolUse: true},
		{ID: "gemini-1.5-flash", SupportsToolUse: true},
		{ID: "gemini-1.5-pro", SupportsToolUse: true},
	}
}

func (p *GeminiProvider) messagesToContents(messages []agentctx.StrategicMessage) []*genai.Content {
	contents := make([]*genai.Content, 0, len(messages))
	for _, msg := range messages {
		if msg.Content == nil && len(msg.ToolCalls) == 0 {
			continue
		}
		role := msg.Role
		if role == "assistant" {
			role = "model"
		}
		c := &genai.Content{Role: role}
		
		// Handle text content
		if msg.Content != nil {
			if msg.Content.Str != nil {
				c.Parts = append(c.Parts, &genai.Part{Text: *msg.Content.Str})
			} else {
				for _, item := range msg.Content.Items {
					if item.Text != nil {
						c.Parts = append(c.Parts, &genai.Part{Text: item.Text.Text})
					}
					// Note: Image and other types can be added here as needed
				}
			}
		}

		// Handle tool calls (assistant turn)
		for _, tc := range msg.ToolCalls {
			name, _ := tc["name"].(string)
			args, _ := tc["args"].(map[string]any)
			c.Parts = append(c.Parts, &genai.Part{
				FunctionCall: &genai.FunctionCall{
					Name: name,
					Args: args,
				},
			})
		}

		// Handle tool results (user turn)
		if msg.Role == "tool" || (msg.Role == "user" && msg.ToolCallID != nil) {
			// In our schema, tool results often come in a message with Role="user" (Gemini requirement)
			// or Role="tool" (generic).
			// If it has a Name and Content, it's a function response.
			if msg.Name != nil && msg.Content != nil && msg.Content.Str != nil {
				var res map[string]any
				// Try to parse content as JSON if it's a map, otherwise wrap it
				if err := json.Unmarshal([]byte(*msg.Content.Str), &res); err != nil {
					res = map[string]any{"output": *msg.Content.Str}
				}
				c.Parts = append(c.Parts, genai.NewPartFromFunctionResponse(*msg.Name, res))
			}
		}

		contents = append(contents, c)
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
		cfg.MaxOutputTokens = int32(req.MaxTokens)
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
				json.Unmarshal(data, &schema)
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
