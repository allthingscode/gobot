//nolint:testpackage // requires unexported provider internals for testing
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

func TestAnthropicProvider_Name(t *testing.T) {
	t.Parallel()
	p := NewAnthropicProvider("test-key", "")
	if p.Name() != "anthropic" {
		t.Errorf("got %q, want %q", p.Name(), "anthropic")
	}
}

func TestAnthropicProvider_Models(t *testing.T) {
	t.Parallel()
	p := NewAnthropicProvider("test-key", "")
	models := p.Models()
	if len(models) == 0 {
		t.Fatal("expected models")
	}
	found := false
	for _, m := range models {
		if m.ID == "claude-3-5-sonnet-20241022" {
			found = true
			if !m.SupportsToolUse {
				t.Error("expected claude-3-5-sonnet to support tool use")
			}
			break
		}
	}
	if !found {
		t.Error("expected claude-3-5-sonnet-20241022 in models")
	}
}

//nolint:cyclop // test complexity justified by multi-step verification
func TestAnthropicProvider_Chat_Success(t *testing.T) {
	t.Parallel()
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("x-api-key") != "test-key" {
			t.Errorf("missing or incorrect api key: %s", r.Header.Get("x-api-key"))
		}

		var req anthropicRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("failed to decode request: %v", err)
		}

		if req.System != "system prompt" {
			t.Errorf("got system %q, want 'system prompt'", req.System)
		}
		if len(req.Messages) != 1 {
			t.Errorf("got %d messages, want 1", len(req.Messages))
		}

		resp := anthropicResponse{
			ID:   "msg_123",
			Type: "message",
			Role: "assistant",
			Content: []anthropicContentBlock{
				{
					Type: "text",
					Text: "hello world",
				},
				{
					Type:  "tool_use",
					ID:    "tool_123",
					Name:  "my_tool",
					Input: map[string]any{"arg1": "val1"},
				},
			},
			Usage: anthropicUsage{
				InputTokens:  10,
				OutputTokens: 20,
			},
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	}))
	defer ts.Close()

	p := NewAnthropicProvider("test-key", ts.URL)
	str := "hello" //nolint:goconst // test fixture
	req := ChatRequest{
		Model:             "claude-3-5-sonnet",
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

	if resp.Usage.PromptTokens != 10 {
		t.Errorf("got %d prompt tokens, want 10", resp.Usage.PromptTokens)
	}
	if resp.Usage.TotalTokens != 30 {
		t.Errorf("got %d total tokens, want 30", resp.Usage.TotalTokens)
	}
	if resp.Message.Content == nil || *resp.Message.Content.Str != "hello world" {
		t.Errorf("unexpected content: %v", resp.Message.Content)
	}
	if len(resp.Message.ToolCalls) != 1 {
		t.Fatalf("got %d tool calls, want 1", len(resp.Message.ToolCalls))
	}
	if resp.Message.ToolCalls[0].Name != "my_tool" { //nolint:goconst // test fixture
		t.Errorf("got tool name %q, want 'my_tool'", resp.Message.ToolCalls[0].Name)
	}
}

func TestAnthropicProvider_Chat_Error(t *testing.T) {
	t.Parallel()
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"type":"error","error":{"type":"invalid_request_error","message":"bad request"}}`))
	}))
	defer ts.Close()

	p := NewAnthropicProvider("test-key", ts.URL)
	req := ChatRequest{
		Model: "claude-3-5-sonnet",
	}

	_, err := p.Chat(context.Background(), req)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !strings.Contains(err.Error(), "invalid_request_error") {
		t.Errorf("expected invalid_request_error, got: %v", err)
	}
}

func TestAnthropicProvider_MergeMessages(t *testing.T) {
	t.Parallel()
	p := NewAnthropicProvider("test-key", "")

	str1 := "msg 1"
	str2 := "msg 2"
	messages := []agentctx.StrategicMessage{
		{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: &str1}},
		{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: &str2}},
	}

	mapped := p.mapMessages(messages)

	if len(mapped) != 1 {
		t.Fatalf("got %d messages, want 1", len(mapped))
	}
	if len(mapped[0].Content) != 2 {
		t.Errorf("got %d content blocks, want 2", len(mapped[0].Content))
	}
}
