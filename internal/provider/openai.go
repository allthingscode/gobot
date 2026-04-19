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
	defaultOpenAIBaseURL    = "https://api.openai.com/v1"
	defaultOpenRouterBaseURL = "https://openrouter.ai/api/v1"
	providerNameOpenAI      = "openai"
	providerNameOpenRouter  = "openrouter"
)

// OpenAIProvider implements the Provider interface for OpenAI-compatible APIs.
type OpenAIProvider struct {
	name    string
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
		name:    providerNameOpenAI,
		apiKey:  apiKey,
		baseURL: baseURL,
		client:  &http.Client{},
	}
}

// NewOpenRouterProvider creates a new OpenAIProvider configured for OpenRouter.
func NewOpenRouterProvider(apiKey, baseURL string) *OpenAIProvider {
	if baseURL == "" {
		baseURL = defaultOpenRouterBaseURL
	}
	// Ensure no trailing slash
	baseURL = strings.TrimSuffix(baseURL, "/")

	return &OpenAIProvider{
		name:    providerNameOpenRouter,
		apiKey:  apiKey,
		baseURL: baseURL,
		client:  &http.Client{},
	}
}

// Name returns the provider name.
func (p *OpenAIProvider) Name() string {
	return p.name
}

func (p *OpenAIProvider) sendRequest(ctx context.Context, url string, jsonData []byte) (*http.Response, error) {
	httpReq, err := http.NewRequestWithContext(ctx, "POST", url, bytes.NewBuffer(jsonData))
	if err != nil {
		return nil, fmt.Errorf("%s: failed to create request: %w", p.name, err)
	}

	httpReq.Header.Set("Content-Type", "application/json")
	if p.apiKey != "" {
		httpReq.Header.Set("Authorization", fmt.Sprintf("Bearer %s", p.apiKey))
	}

	// OpenRouter specific headers for identification (optional but recommended)
	if p.name == providerNameOpenRouter {
		httpReq.Header.Set("HTTP-Referer", "https://github.com/allthingscode/gobot")
		httpReq.Header.Set("X-Title", "Gobot Strategic Edition")
	}

	resp, err := p.client.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("%s: http request: %w", p.name, err)
	}
	return resp, nil
}

func (p *OpenAIProvider) parseErrorResponse(body []byte, statusCode int) error {
	var errResp struct {
		Error struct {
			Message string `json:"message"`
			Type    string `json:"type"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &errResp); err == nil && errResp.Error.Message != "" {
		return fmt.Errorf("%s api error (%s): %s", p.name, errResp.Error.Type, errResp.Error.Message)
	}
	return fmt.Errorf("%s api error: status %d, body: %s", p.name, statusCode, string(body))
}

func (p *OpenAIProvider) Chat(ctx context.Context, req ChatRequest) (*ChatResponse, error) {
	model := req.Model
	if p.name == providerNameOpenRouter {
		model = strings.TrimPrefix(model, "openrouter/")
	}

	oaReq := openAIRequest{
		Model:       model,
		MaxTokens:   req.MaxTokens,
		Temperature: req.Temperature,
		Messages:    p.mapMessages(req.Messages, req.SystemInstruction),
		Tools:       p.mapTools(req.Tools),
	}

	jsonData, err := json.Marshal(oaReq)
	if err != nil {
		return nil, fmt.Errorf("%s: failed to marshal request: %w", p.name, err)
	}

	url := fmt.Sprintf("%s/chat/completions", p.baseURL)
	resp, err := p.sendRequest(ctx, url, jsonData)
	if err != nil {
		return nil, fmt.Errorf("%s: request failed: %w", p.name, err)
	}
	defer func() { _ = resp.Body.Close() }()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("%s: failed to read response: %w", p.name, err)
	}

	if resp.StatusCode != http.StatusOK {
		return nil, p.parseErrorResponse(body, resp.StatusCode)
	}

	var oaResp openAIResponse
	if err := json.Unmarshal(body, &oaResp); err != nil {
		return nil, fmt.Errorf("%s: failed to unmarshal response: %w", p.name, err)
	}

	if len(oaResp.Choices) == 0 {
		return nil, fmt.Errorf("%s: no choices returned", p.name)
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
	result := make([]openAIMessage, 0, len(messages)+1)

	if system != "" {
		result = append(result, openAIMessage{
			Role:    string(agentctx.RoleSystem),
			Content: system,
		})
	}

	for _, msg := range messages {
		result = append(result, mapSingleMessage(msg))
	}

	return result
}

func mapSingleMessage(msg agentctx.StrategicMessage) openAIMessage {
	oaMsg := openAIMessage{
		Role: string(msg.Role),
	}

	if msg.Content != nil {
		oaMsg.Content = mapMessageContent(msg.Content)
	}

	if msg.Role == agentctx.RoleAssistant && len(msg.ToolCalls) > 0 {
		oaMsg.ToolCalls = mapToolCalls(msg.ToolCalls)
	}

	if msg.Role == agentctx.RoleTool && msg.ToolCallID != nil {
		oaMsg.ToolCallID = *msg.ToolCallID
	}

	return oaMsg
}

func mapMessageContent(content *agentctx.MessageContent) string {
	if content.Str != nil {
		return *content.Str
	}
	var parts []string
	for _, item := range content.Items {
		if item.Text != nil {
			parts = append(parts, item.Text.Text)
		}
	}
	return strings.Join(parts, "\n")
}

func mapToolCalls(toolCalls []agentctx.ToolCall) []openAIToolCall {
	oaToolCalls := make([]openAIToolCall, 0, len(toolCalls))
	for _, tc := range toolCalls {
		id := tc.ID
		name := tc.Name
		argsMap := tc.Args
		argsBytes, _ := json.Marshal(argsMap)
		oaToolCalls = append(oaToolCalls, openAIToolCall{
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
	return oaToolCalls
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
		Role: agentctx.RoleAssistant,
	}

	if choice.Message.Content != "" {
		msg.Content = &agentctx.MessageContent{Str: &choice.Message.Content}
	}

	for _, tc := range choice.Message.ToolCalls {
		var args map[string]any
		_ = json.Unmarshal([]byte(tc.Function.Arguments), &args)

		msg.ToolCalls = append(msg.ToolCalls, agentctx.ToolCall{
			ID:   tc.ID,
			Name: tc.Function.Name,
			Args: args,
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

// OpenAI API types.
type openAIRequest struct {
	Model       string          `json:"model"`
	Messages    []openAIMessage `json:"messages"`
	MaxTokens   int             `json:"max_tokens,omitempty"`
	Temperature float32         `json:"temperature,omitempty"`
	Tools       []openAITool    `json:"tools,omitempty"`
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
