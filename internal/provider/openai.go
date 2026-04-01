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
	defaultOpenAIBaseURL = "https://api.openai.com/v1"
)

// OpenAIProvider implements the Provider interface for OpenAI-compatible APIs.
type OpenAIProvider struct {
	apiKey  string
	baseURL string
	client  *http.Client
}

// NewOpenAIProvider creates a new OpenAIProvider.
func NewOpenAIProvider(apiKey, baseURL string) *OpenAIProvider {
	if baseURL == "" {
		baseURL = defaultOpenAIBaseURL
	}
	// Ensure no trailing slash
	baseURL = strings.TrimSuffix(baseURL, "/")

	return &OpenAIProvider{
		apiKey:  apiKey,
		baseURL: baseURL,
		client:  &http.Client{},
	}
}

// Name returns the provider name.
func (p *OpenAIProvider) Name() string {
	return "openai"
}

// Chat executes a single-turn LLM call via an OpenAI-compatible API.
func (p *OpenAIProvider) Chat(ctx context.Context, req ChatRequest) (*ChatResponse, error) {
	oaReq := openAIRequest{
		Model:       req.Model,
		MaxTokens:   req.MaxTokens,
		Temperature: req.Temperature,
		Messages:    p.mapMessages(req.Messages, req.SystemInstruction),
		Tools:       p.mapTools(req.Tools),
	}

	jsonData, err := json.Marshal(oaReq)
	if err != nil {
		return nil, fmt.Errorf("openai: failed to marshal request: %w", err)
	}

	url := fmt.Sprintf("%s/chat/completions", p.baseURL)
	httpReq, err := http.NewRequestWithContext(ctx, "POST", url, bytes.NewBuffer(jsonData))
	if err != nil {
		return nil, fmt.Errorf("openai: failed to create request: %w", err)
	}

	httpReq.Header.Set("Content-Type", "application/json")
	if p.apiKey != "" {
		httpReq.Header.Set("Authorization", fmt.Sprintf("Bearer %s", p.apiKey))
	}

	resp, err := p.client.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("openai: request failed: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("openai: failed to read response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		var errResp struct {
			Error struct {
				Message string `json:"message"`
				Type    string `json:"type"`
			} `json:"error"`
		}
		if err := json.Unmarshal(body, &errResp); err == nil && errResp.Error.Message != "" {
			return nil, fmt.Errorf("openai api error (%s): %s", errResp.Error.Type, errResp.Error.Message)
		}
		return nil, fmt.Errorf("openai api error: status %d, body: %s", resp.StatusCode, string(body))
	}

	var oaResp openAIResponse
	if err := json.Unmarshal(body, &oaResp); err != nil {
		return nil, fmt.Errorf("openai: failed to unmarshal response: %w", err)
	}

	if len(oaResp.Choices) == 0 {
		return nil, fmt.Errorf("openai: no choices returned")
	}

	return p.mapResponse(oaResp), nil
}

// Models returns a list of common OpenAI models.
func (p *OpenAIProvider) Models() []ModelInfo {
	return []ModelInfo{
		{ID: "gpt-4o", SupportsToolUse: true},
		{ID: "gpt-4o-mini", SupportsToolUse: true},
		{ID: "gpt-4-turbo", SupportsToolUse: true},
		{ID: "gpt-3.5-turbo", SupportsToolUse: true},
		{ID: "o1-preview", SupportsToolUse: true},
		{ID: "o1-mini", SupportsToolUse: true},
	}
}

func (p *OpenAIProvider) mapMessages(messages []agentctx.StrategicMessage, system string) []openAIMessage {
	var result []openAIMessage

	if system != "" {
		result = append(result, openAIMessage{
			Role:    "system",
			Content: system,
		})
	}

	for _, msg := range messages {
		oaMsg := openAIMessage{
			Role: string(msg.Role),
		}

		if msg.Content != nil {
			if msg.Content.Str != nil {
				oaMsg.Content = *msg.Content.Str
			} else {
				var parts []string
				for _, item := range msg.Content.Items {
					if item.Text != nil {
						parts = append(parts, item.Text.Text)
					}
				}
				oaMsg.Content = strings.Join(parts, "\n")
			}
		}

		if msg.Role == "assistant" && len(msg.ToolCalls) > 0 {
			for _, tc := range msg.ToolCalls {
				id, _ := tc["id"].(string)
				name, _ := tc["name"].(string)
				argsMap, _ := tc["args"].(map[string]any)
				argsBytes, _ := json.Marshal(argsMap)
				oaMsg.ToolCalls = append(oaMsg.ToolCalls, openAIToolCall{
					ID:   id,
					Type: "function",
					Function: struct {
						Name      string `json:"name"`
						Arguments string `json:"arguments"`
					}{
						Name:      name,
						Arguments: string(argsBytes),
					},
				})
			}
		}

		if msg.Role == "tool" && msg.ToolCallID != nil {
			oaMsg.ToolCallID = *msg.ToolCallID
		}

		result = append(result, oaMsg)
	}

	return result
}

func (p *OpenAIProvider) mapTools(tools []ToolDeclaration) []openAITool {
	if len(tools) == 0 {
		return nil
	}
	result := make([]openAITool, len(tools))
	for i, t := range tools {
		result[i] = openAITool{
			Type: "function",
			Function: struct {
				Name        string         `json:"name"`
				Description string         `json:"description,omitempty"`
				Parameters  map[string]any `json:"parameters"`
			}{
				Name:        t.Name,
				Description: t.Description,
				Parameters:  t.Parameters,
			},
		}
	}
	return result
}

func (p *OpenAIProvider) mapResponse(oaResp openAIResponse) *ChatResponse {
	choice := oaResp.Choices[0]
	msg := agentctx.StrategicMessage{
		Role: "assistant",
	}

	if choice.Message.Content != "" {
		msg.Content = &agentctx.MessageContent{Str: &choice.Message.Content}
	}

	for _, tc := range choice.Message.ToolCalls {
		var args map[string]any
		_ = json.Unmarshal([]byte(tc.Function.Arguments), &args)

		msg.ToolCalls = append(msg.ToolCalls, map[string]any{
			"id":   tc.ID,
			"name": tc.Function.Name,
			"args": args,
		})
	}

	usage := TokenUsage{
		PromptTokens:     oaResp.Usage.PromptTokens,
		CompletionTokens: oaResp.Usage.CompletionTokens,
		TotalTokens:      oaResp.Usage.TotalTokens,
	}

	return &ChatResponse{
		Message: msg,
		Usage:   usage,
	}
}

// OpenAI API types
type openAIRequest struct {
	Model       string           `json:"model"`
	Messages    []openAIMessage  `json:"messages"`
	MaxTokens   int              `json:"max_tokens,omitempty"`
	Temperature float32          `json:"temperature,omitempty"`
	Tools       []openAITool     `json:"tools,omitempty"`
}

type openAIMessage struct {
	Role       string           `json:"role"`
	Content    string           `json:"content,omitempty"`
	ToolCalls  []openAIToolCall `json:"tool_calls,omitempty"`
	ToolCallID string           `json:"tool_call_id,omitempty"`
}

type openAIToolCall struct {
	ID       string `json:"id"`
	Type     string `json:"type"`
	Function struct {
		Name      string `json:"name"`
		Arguments string `json:"arguments"`
	} `json:"function"`
}

type openAITool struct {
	Type     string `json:"type"`
	Function struct {
		Name        string         `json:"name"`
		Description string         `json:"description,omitempty"`
		Parameters  map[string]any `json:"parameters"`
	} `json:"function"`
}

type openAIResponse struct {
	Choices []struct {
		Message struct {
			Role      string           `json:"role"`
			Content   string           `json:"content"`
			ToolCalls []openAIToolCall `json:"tool_calls"`
		} `json:"message"`
	} `json:"choices"`
	Usage struct {
		PromptTokens     int `json:"prompt_tokens"`
		CompletionTokens int `json:"completion_tokens"`
		TotalTokens      int `json:"total_tokens"`
	} `json:"usage"`
}
