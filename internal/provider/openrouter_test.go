//nolint:testpackage // requires unexported openai provider internals for testing
package provider

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	agentctx "github.com/allthingscode/gobot/internal/context"
)

func TestOpenRouterProvider_Name(t *testing.T) {
	t.Parallel()
	p := NewOpenRouterProvider("test-key", "")
	if p.Name() != "openrouter" {
		t.Errorf("got %q, want %q", p.Name(), "openrouter")
	}
}

func TestOpenRouterProvider_Chat_PrefixStripping(t *testing.T) {
	t.Parallel()
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer test-key" {
			t.Errorf("missing or incorrect auth header: %s", r.Header.Get("Authorization"))
		}
		if r.Header.Get("X-Title") != "Gobot Strategic Edition" {
			t.Errorf("missing or incorrect X-Title header: %s", r.Header.Get("X-Title"))
		}

		var req openAIRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("failed to decode request: %v", err)
		}

		// The prefix "openrouter/" should be stripped.
		if req.Model != "mistralai/mistral-7b-instruct" {
			t.Errorf("got model %q, want %q", req.Model, "mistralai/mistral-7b-instruct")
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
				Content: "hello from openrouter",
			},
		})
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	}))
	defer ts.Close()

	p := NewOpenRouterProvider("test-key", ts.URL)
	str := "hello"
	req := ChatRequest{
		Model: "openrouter/mistralai/mistral-7b-instruct",
		Messages: []agentctx.StrategicMessage{
			{
				Role:    agentctx.RoleUser,
				Content: &agentctx.MessageContent{Str: &str},
			},
		},
	}

	resp, err := p.Chat(context.Background(), req)
	if err != nil {
		t.Fatalf("Chat failed: %v", err)
	}

	if resp.Message.Content == nil || *resp.Message.Content.Str != "hello from openrouter" {
		t.Errorf("unexpected content: %v", resp.Message.Content)
	}
}
