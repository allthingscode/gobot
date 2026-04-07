package gateway

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
)

// mockHandler implements bot.Handler for testing.
type mockHandler struct {
	lastMsg string
}

func (m *mockHandler) Handle(_ context.Context, _ string, msg bot.InboundMessage) (string, error) {
	m.lastMsg = msg.Text
	return "Reply: " + msg.Text, nil
}

func (m *mockHandler) HandleCallback(_ context.Context, _ bot.InboundCallback) error {
	return nil
}

func TestGateway(t *testing.T) {
	cfg := config.GatewayConfig{Enabled: true, Host: "localhost", Port: 18790}
	h := &mockHandler{}
	srv := NewServer(cfg, h)

	t.Run("Health", func(t *testing.T) {
		req := httptest.NewRequest("GET", "/health", http.NoBody)
		w := httptest.NewRecorder()
		srv.handleHealth(w, req)

		if w.Code != http.StatusOK {
			t.Errorf("expected 200, got %d", w.Code)
		}
		if w.Body.String() != "OK" {
			t.Errorf("expected OK, got %q", w.Body.String())
		}
	})

	t.Run("Chat", func(t *testing.T) {
		in := InboundRequest{
			SessionKey: "test-session",
			Text:       "hello gateway",
		}
		body, _ := json.Marshal(in)
		req := httptest.NewRequest("POST", "/chat", bytes.NewReader(body))
		w := httptest.NewRecorder()
		srv.handleChat(w, req)

		if w.Code != http.StatusOK {
			t.Errorf("expected 200, got %d", w.Code)
		}

		var resp OutboundResponse
		if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
			t.Fatalf("failed to decode response: %v", err)
		}

		if resp.Reply != "Reply: hello gateway" {
			t.Errorf("unexpected reply: %q", resp.Reply)
		}
		if h.lastMsg != "hello gateway" {
			t.Errorf("handler did not receive correct message: %q", h.lastMsg)
		}
	})

	t.Run("InvalidMethod", func(t *testing.T) {
		req := httptest.NewRequest("GET", "/chat", http.NoBody)
		w := httptest.NewRecorder()
		srv.handleChat(w, req)

		if w.Code != http.StatusMethodNotAllowed {
			t.Errorf("expected 405, got %d", w.Code)
		}
	})
}
