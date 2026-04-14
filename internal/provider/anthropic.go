package provider

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"

	agentctx "github.com/allthingscode/gobot/internal/context"
)

const (
	defaultAnthropicAPIURL = "https://api.anthropic.com/v1/messages"
	anthropicVersion       = "2023-06-01"
)

// AnthropicProvider implements the Provider interface for Anthropic's Claude models.
type AnthropicProvider struct {
	apiKey  string
	baseURL string
	client  *http.Client
}

// NewAnthropicProvider creates a new AnthropicProvider.
func NewAnthropicProvider(apiKey, baseURL string) *AnthropicProvider {
	if baseURL == "" {
		baseURL = defaultAnthropicAPIURL
	}
	return &AnthropicProvider{
		apiKey:  apiKey,
		baseURL: baseURL,
		client:  &http.Client{},
	}
}

// Name returns the provider name.
func (p *AnthropicProvider) Name() string {
	return "anthropic"
}

// Chat executes a single-turn LLM call via the Anthropic API.
func (p *AnthropicProvider) Chat(ctx context.Context, req ChatRequest) (*ChatResponse, error) {
	antReq := anthropicRequest{
		Model:       req.Model,
		System:      req.SystemInstruction,
		MaxTokens:   req.MaxTokens,
		Temperature: req.Temperature,
	}

	if antReq.MaxTokens <= 0 {
		antReq.MaxTokens = 4096 // Default if not specified
	}

	antReq.Messages = p.mapMessages(req.Messages)
	antReq.Tools = p.mapTools(req.Tools)

	jsonData, err := json.Marshal(antReq)
	if err != nil {
		return nil, fmt.Errorf("anthropic: failed to marshal request: %w", err)
	}

	httpReq, err := http.NewRequestWithContext(ctx, "POST", p.baseURL, bytes.NewBuffer(jsonData))
	if err != nil {
		return nil, fmt.Errorf("anthropic: failed to create request: %w", err)
	}

	httpReq.Header.Set("x-api-key", p.apiKey)
	httpReq.Header.Set("anthropic-version", anthropicVersion)
	httpReq.Header.Set("content-type", "application/json")

	resp, err := p.client.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("anthropic: request failed: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("anthropic: failed to read response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		var errResp struct {
			Type  string `json:"type"`
			Error struct {
				Type    string `json:"type"`
				Message string `json:"message"`
			} `json:"error"`
		}
		if err := json.Unmarshal(body, &errResp); err == nil {
			if errResp.Error.Message != "" {
				return nil, fmt.Errorf("anthropic api error (%s): %s", errResp.Error.Type, errResp.Error.Message)
			}
		}
		return nil, fmt.Errorf("anthropic api error: status %d, body: %s", resp.StatusCode, string(body))
	}

	var antResp anthropicResponse
	if err := json.Unmarshal(body, &antResp); err != nil {
		return nil, fmt.Errorf("anthropic: failed to unmarshal response: %w", err)
	}

	return p.mapResponse(antResp), nil
}

// Models returns a list of supported Claude models.
func (p *AnthropicProvider) Models() []ModelInfo {
	return []ModelInfo{
		{ID: "claude-3-7-sonnet-20250219", SupportsToolUse: true},
		{ID: "claude-3-5-sonnet-20241022", SupportsToolUse: true},
		{ID: "claude-3-5-haiku-20241022", SupportsToolUse: true},
		{ID: "claude-3-opus-20240229", SupportsToolUse: true},
	}
}

func (p *AnthropicProvider) mapMessages(messages []agentctx.StrategicMessage) []anthropicMessage {
	var result []anthropicMessage
	var currentMsg *anthropicMessage

	for _, msg := range messages {
		role := string(msg.Role)
		if msg.Role == agentctx.RoleTool {
			role = string(agentctx.RoleUser)
		}

		blocks := p.mapContentBlocks(msg)
		if len(blocks) == 0 {
			continue
		}

		// Merge consecutive same-role messages (Anthropic requirement: alternating roles)
		if currentMsg != nil && currentMsg.Role == role {
			currentMsg.Content = append(currentMsg.Content, blocks...)
		} else {
			if currentMsg != nil {
				result = append(result, *currentMsg)
			}
			currentMsg = &anthropicMessage{
				Role:    role,
				Content: blocks,
			}
		}
	}

	if currentMsg != nil {
		result = append(result, *currentMsg)
	}

	return result
}

func (p *AnthropicProvider) mapContentBlocks(msg agentctx.StrategicMessage) []anthropicContentBlock {
	blocks := make([]anthropicContentBlock, 0, 4)

	blocks = append(blocks, mapTextBlocks(msg.Content)...)
	blocks = append(blocks, mapToolCallBlocks(msg.ToolCalls)...)

	if resultBlock, ok := mapToolResultBlock(msg); ok {
		blocks = append(blocks, resultBlock)
	}

	return blocks
}

func mapTextBlocks(content *agentctx.MessageContent) []anthropicContentBlock {
	if content == nil {
		return nil
	}

	if content.Str != nil {
		return []anthropicContentBlock{{
			Type: "text",
			Text: *content.Str,
		}}
	}

	var blocks []anthropicContentBlock
	for _, item := range content.Items {
		if item.Text != nil {
			blocks = append(blocks, anthropicContentBlock{
				Type: "text",
				Text: item.Text.Text,
			})
		}
	}
	return blocks
}

func mapToolCallBlocks(toolCalls []agentctx.ToolCall) []anthropicContentBlock {
	blocks := make([]anthropicContentBlock, 0, len(toolCalls))
	for _, tc := range toolCalls {
		id := tc.ID
		name := tc.Name
		args := tc.Args
		blocks = append(blocks, anthropicContentBlock{
			Type:  "tool_use",
			ID:    id,
			Name:  name,
			Input: args,
		})
	}
	return blocks
}

func mapToolResultBlock(msg agentctx.StrategicMessage) (anthropicContentBlock, bool) {
	if msg.Role != agentctx.RoleTool && (msg.Role != agentctx.RoleUser || msg.ToolCallID == nil) {
		return anthropicContentBlock{}, false
	}

	if msg.ToolCallID == nil {
		return anthropicContentBlock{}, false
	}

	content := ""
	if msg.Content != nil && msg.Content.Str != nil {
		content = *msg.Content.Str
	}

	return anthropicContentBlock{
		Type:      "tool_result",
		ToolUseID: *msg.ToolCallID,
		Content:   content,
	}, true
}

func (p *AnthropicProvider) mapTools(tools []ToolDeclaration) []anthropicTool {
	if len(tools) == 0 {
		return nil
	}
	result := make([]anthropicTool, len(tools))
	for i, t := range tools {
		result[i] = anthropicTool{
			Name:        t.Name,
			Description: t.Description,
			InputSchema: t.Parameters,
		}
	}
	return result
}

func (p *AnthropicProvider) mapResponse(antResp anthropicResponse) *ChatResponse {
	msg := agentctx.StrategicMessage{
		Role: agentctx.RoleAssistant,
	}

	var textParts []string
	for _, block := range antResp.Content {
		switch block.Type {
		case "text":
			textParts = append(textParts, block.Text)
		case "tool_use":
			msg.ToolCalls = append(msg.ToolCalls, agentctx.ToolCall{
				ID:   block.ID,
				Name: block.Name,
				Args: block.Input,
			})
		}
	}

	if len(textParts) > 0 {
		text := strings.Join(textParts, "\n")
		msg.Content = &agentctx.MessageContent{Str: &text}
	}

	usage := TokenUsage{
		PromptTokens:     antResp.Usage.InputTokens,
		CompletionTokens: antResp.Usage.OutputTokens,
		TotalTokens:      antResp.Usage.InputTokens + antResp.Usage.OutputTokens,
	}

	return &ChatResponse{
		Message: msg,
		Usage:   usage,
	}
}

// Anthropic API types.
type anthropicRequest struct {
	Model       string             `json:"model"`
	Messages    []anthropicMessage `json:"messages"`
	System      string             `json:"system,omitempty"`
	MaxTokens   int                `json:"max_tokens"`
	Temperature float32            `json:"temperature,omitempty"`
	Tools       []anthropicTool    `json:"tools,omitempty"`
}

type anthropicMessage struct {
	Role    string                  `json:"role"`
	Content []anthropicContentBlock `json:"content"`
}

type anthropicContentBlock struct {
	Type      string         `json:"type"`
	Text      string         `json:"text,omitempty"`
	ID        string         `json:"id,omitempty"`          // for tool_use
	Name      string         `json:"name,omitempty"`        // for tool_use
	Input     map[string]any `json:"input,omitempty"`       // for tool_use
	ToolUseID string         `json:"tool_use_id,omitempty"` // for tool_result
	Content   any            `json:"content,omitempty"`     // for tool_result
}

type anthropicTool struct {
	Name        string         `json:"name"`
	Description string         `json:"description,omitempty"`
	InputSchema map[string]any `json:"input_schema"`
}

type anthropicResponse struct {
	ID      string                  `json:"id"`
	Type    string                  `json:"type"`
	Role    string                  `json:"role"`
	Content []anthropicContentBlock `json:"content"`
	Usage   anthropicUsage          `json:"usage"`
}

type anthropicUsage struct {
	InputTokens  int `json:"input_tokens"`
	OutputTokens int `json:"output_tokens"`
}
