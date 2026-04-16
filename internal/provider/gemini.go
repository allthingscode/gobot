package provider

import (
	"context"
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

// Client returns the underlying genai.Client.
func (p *GeminiProvider) Client() *genai.Client {
	return p.client
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
		return nil, fmt.Errorf("gemini generate: %w", err)
	}

	if len(resp.Candidates) == 0 || resp.Candidates[0].Content == nil {
		return nil, fmt.Errorf("gemini: no candidates returned")
	}

	return p.mapResponse(resp), nil
}

func (p *GeminiProvider) mapResponse(resp *genai.GenerateContentResponse) *ChatResponse {
	candidate := resp.Candidates[0]
	msg := agentctx.StrategicMessage{
		Role: agentctx.RoleAssistant,
	}

	p.mapParts(candidate.Content.Parts, &msg)

	usage := TokenUsage{}
	if resp.UsageMetadata != nil {
		usage.PromptTokens = int(resp.UsageMetadata.PromptTokenCount)
		usage.CompletionTokens = int(resp.UsageMetadata.CandidatesTokenCount)
		usage.TotalTokens = int(resp.UsageMetadata.TotalTokenCount)
	}

	return &ChatResponse{
		Message: msg,
		Usage:   usage,
	}
}

func (p *GeminiProvider) mapParts(parts []*genai.Part, msg *agentctx.StrategicMessage) {
	var textParts []string
	var lastThoughtSig []byte

	for _, part := range parts {
		switch {
		case part.Thought:
			p.mapThoughtPart(part, msg, &lastThoughtSig)
		case part.FunctionCall != nil:
			p.mapFunctionCallPart(part, msg, lastThoughtSig)
		case part.Text != "":
			textParts = append(textParts, part.Text)
		}
	}

	if len(textParts) > 0 {
		text := strings.Join(textParts, "\n")
		msg.Content = &agentctx.MessageContent{Str: &text}
	}
}

func (p *GeminiProvider) mapThoughtPart(part *genai.Part, msg *agentctx.StrategicMessage, lastThoughtSig *[]byte) {
	msg.ThinkingBlocks = append(msg.ThinkingBlocks, map[string]any{
		"text":              part.Text,
		"thought_signature": part.ThoughtSignature,
	})
	*lastThoughtSig = part.ThoughtSignature
	if msg.ReasoningContent == nil {
		msg.ReasoningContent = &part.Text
	} else {
		combined := *msg.ReasoningContent + "\n" + part.Text
		msg.ReasoningContent = &combined
	}
}

func (p *GeminiProvider) mapFunctionCallPart(part *genai.Part, msg *agentctx.StrategicMessage, lastThoughtSig []byte) {
	tc := agentctx.ToolCall{
		Name: part.FunctionCall.Name,
		Args: part.FunctionCall.Args,
	}
	sig := part.ThoughtSignature
	if len(sig) == 0 {
		sig = lastThoughtSig
	}
	if len(sig) > 0 {
		tc.ThoughtSignature = sig
	}
	msg.ToolCalls = append(msg.ToolCalls, tc)
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
		if isEmptyMessage(msg) {
			slog.Debug("gemini: skipping empty message", "index", i, "role", string(msg.Role))
			continue
		}

		c := &genai.Content{Role: mapRole(msg.Role)}
		p.appendPartsToContent(c, msg)

		if len(c.Parts) > 0 {
			contents = append(contents, c)
		} else {
			slog.Debug("gemini: message yielded no parts, omitting", "index", i, "role", string(msg.Role))
		}
	}
	return contents
}

func isEmptyMessage(msg agentctx.StrategicMessage) bool {
	return msg.Content == nil && len(msg.ToolCalls) == 0 && msg.Name == nil && len(msg.ThinkingBlocks) == 0
}

func mapRole(role agentctx.MessageRole) string {
	switch role {
	case agentctx.RoleAssistant:
		return string(agentctx.RoleModel)
	case agentctx.RoleTool:
		return string(agentctx.RoleUser)
	default:
		return string(role)
	}
}

func (p *GeminiProvider) appendPartsToContent(c *genai.Content, msg agentctx.StrategicMessage) {
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
		appendContentParts(c, msg.Content)
	}

	// Handle tool calls (assistant turn)
	if len(msg.ToolCalls) > 0 {
		appendToolCallParts(c, msg.ToolCalls)
	}

	// Handle tool results (user turn)
	if msg.Role == agentctx.RoleTool || (msg.Role == agentctx.RoleUser && msg.ToolCallID != nil) {
		appendToolResultPart(c, msg)
	}
}

func appendContentParts(c *genai.Content, content *agentctx.MessageContent) {
	if content.Str != nil && *content.Str != "" {
		c.Parts = append(c.Parts, &genai.Part{Text: *content.Str})
	} else {
		for _, item := range content.Items {
			if item.Text != nil && item.Text.Text != "" {
				c.Parts = append(c.Parts, &genai.Part{Text: item.Text.Text})
			}
		}
	}
}

func appendToolCallParts(c *genai.Content, toolCalls []agentctx.ToolCall) {
	for _, tc := range toolCalls {
		name := tc.Name
		args := tc.Args
		sig := tc.ThoughtSignature

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
}

func appendToolResultPart(c *genai.Content, msg agentctx.StrategicMessage) {
	if msg.Name != nil && msg.Content != nil && msg.Content.Str != nil {
		var res map[string]any
		if err := json.Unmarshal([]byte(*msg.Content.Str), &res); err != nil {
			res = map[string]any{"output": *msg.Content.Str}
		}
		c.Parts = append(c.Parts, genai.NewPartFromFunctionResponse(*msg.Name, res))
	}
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
