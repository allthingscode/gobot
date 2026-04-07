package provider

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	agentctx "github.com/allthingscode/gobot/internal/context"
)

func TestOpenAIProvider_Name(t *testing.T) {
	t.Parallel()
	p := NewOpenAIProvider("test-key", "")
	if p.Name() != "openai" {
		t.Errorf("got %q, want %q", p.Name(), "openai")
	}
}

func TestOpenAIProvider_Models(t *testing.T) {
	t.Parallel()
	p := NewOpenAIProvider("test-key", "")
	models := p.Models()
	if len(models) == 0 {
		t.Fatal("expected models")
	}
	found := false
	for _, m := range models {
		if m.ID == "gpt-4o" {
			found = true
			if !m.SupportsToolUse {
				t.Error("expected gpt-4o to support tool use")
			}
			break
		}
	}
	if !found {
		t.Error("expected gpt-4o in models")
	}
}

func TestOpenAIProvider_Chat_Success(t *testing.T) {
	t.Parallel()
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer test-key" {
			t.Errorf("missing or incorrect auth header: %s", r.Header.Get("Authorization"))
		}

		var req openAIRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("failed to decode request: %v", err)
		}

		if len(req.Messages) != 2 {
			t.Errorf("got %d messages, want 2 (system + user)", len(req.Messages))
		}
		if req.Messages[0].Role != "system" {
			t.Errorf("got first role %q, want 'system'", req.Messages[0].Role)
		}

		resp := openAIResponse{}
		resp.Choices = append(resp.Choices, struct {
			Message struct {
				Role      string           `json:"role"`
				Content   string           `json:"content"`
				ToolCalls []openAIToolCall `json:"tool_calls"`
			} `json:"message"`
		}{
			Message: struct {
				Role      string           `json:"role"`
				Content   string           `json:"content"`
				ToolCalls []openAIToolCall `json:"tool_calls"`
			}{
				Role:    "assistant",
				Content: "hello from openai",
				ToolCalls: []openAIToolCall{
					{
						ID:   "call_123",
						Type: "function",
						Function: struct {
							Name      string `json:"name"`
							Arguments string `json:"arguments"`
						}{
							Name:      "my_tool",
							Arguments: `{"arg1":"val1"}`,
						},
					},
				},
			},
		})
		resp.Usage.PromptTokens = 5
		resp.Usage.CompletionTokens = 15
		resp.Usage.TotalTokens = 20

		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	}))
	defer ts.Close()

	p := NewOpenAIProvider("test-key", ts.URL)
	str := "hello"
	req := ChatRequest{
		Model:             "gpt-4o",
		SystemInstruction: "system prompt",
		Messages: []agentctx.StrategicMessage{
			{
				Role:    agentctx.RoleUser,
				Content: &agentctx.MessageContent{Str: &str},
			},
		},
		MaxTokens: 100,
	}

	resp, err := p.Chat(context.Background(), req)
	if err != nil {
		t.Fatalf("Chat failed: %v", err)
	}

	if resp.Usage.PromptTokens != 5 {
		t.Errorf("got %d prompt tokens, want 5", resp.Usage.PromptTokens)
	}
	if resp.Usage.TotalTokens != 20 {
		t.Errorf("got %d total tokens, want 20", resp.Usage.TotalTokens)
	}
	if resp.Message.Content == nil || *resp.Message.Content.Str != "hello from openai" {
		t.Errorf("unexpected content: %v", resp.Message.Content)
	}
	if len(resp.Message.ToolCalls) != 1 {
		t.Fatalf("got %d tool calls, want 1", len(resp.Message.ToolCalls))
	}
	if resp.Message.ToolCalls[0]["name"] != "my_tool" {
		t.Errorf("got tool name %q, want 'my_tool'", resp.Message.ToolCalls[0]["name"])
	}
}

func TestOpenAIProvider_Chat_Error(t *testing.T) {
	t.Parallel()
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":{"type":"invalid_request_error","message":"bad request"}}`))
	}))
	defer ts.Close()

	p := NewOpenAIProvider("test-key", ts.URL)
	req := ChatRequest{
		Model: "gpt-4o",
	}

	_, err := p.Chat(context.Background(), req)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !strings.Contains(err.Error(), "invalid_request_error") {
		t.Errorf("expected invalid_request_error, got: %v", err)
	}
}
