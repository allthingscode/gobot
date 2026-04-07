package gateway

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
)

// mockHandler implements bot.Handler for testing.
type mockHandler struct {
	lastMsg string
	err     bool
}

func (m *mockHandler) Handle(_ context.Context, _ string, msg bot.InboundMessage) (string, error) {
	if m.err {
		return "", errors.New("mock error")
	}
	m.lastMsg = msg.Text
	return "Reply: " + msg.Text, nil
}

func (m *mockHandler) HandleCallback(_ context.Context, _ bot.InboundCallback) error {
	return nil
}

func TestGateway(t *testing.T) {
	t.Parallel()
	cfg := config.GatewayConfig{Enabled: true, Host: "localhost", Port: 18790}
	h := &mockHandler{}
	srv := NewServer(cfg, h)

	t.Run("Health", func(t *testing.T) {
		t.Parallel()
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
		t.Parallel()
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

	t.Run("Chat_DefaultSession", func(t *testing.T) {
		t.Parallel()
		in := InboundRequest{
			Text: "no session",
		}
		body, _ := json.Marshal(in)
		req := httptest.NewRequest("POST", "/chat", bytes.NewReader(body))
		w := httptest.NewRecorder()
		srv.handleChat(w, req)

		if w.Code != http.StatusOK {
			t.Errorf("expected 200, got %d", w.Code)
		}
	})

	t.Run("InvalidMethod", func(t *testing.T) {
		t.Parallel()
		req := httptest.NewRequest("GET", "/chat", http.NoBody)
		w := httptest.NewRecorder()
		srv.handleChat(w, req)

		if w.Code != http.StatusMethodNotAllowed {
			t.Errorf("expected 405, got %d", w.Code)
		}
	})

	t.Run("InvalidJSON", func(t *testing.T) {
		t.Parallel()
		req := httptest.NewRequest("POST", "/chat", bytes.NewReader([]byte("not json")))
		w := httptest.NewRecorder()
		srv.handleChat(w, req)

		if w.Code != http.StatusBadRequest {
			t.Errorf("expected 400, got %d", w.Code)
		}
	})

	t.Run("HandlerError", func(t *testing.T) {
		t.Parallel()
		hErr := &mockHandler{err: true}
		srvErr := NewServer(cfg, hErr)
		in := InboundRequest{Text: "fail"}
		body, _ := json.Marshal(in)
		req := httptest.NewRequest("POST", "/chat", bytes.NewReader(body))
		w := httptest.NewRecorder()
		srvErr.handleChat(w, req)

		var resp OutboundResponse
		_ = json.NewDecoder(w.Body).Decode(&resp)
		if resp.Error != "mock error" {
			t.Errorf("expected mock error, got %q", resp.Error)
		}
	})
}

func TestGateway_ListenAndServe(t *testing.T) {
	t.Parallel()
	cfg := config.GatewayConfig{Host: "localhost", Port: 0}
	h := &mockHandler{}
	srv := NewServer(cfg, h)

	ctx, cancel := context.WithCancel(context.Background())
	errChan := make(chan error, 1)
	go func() {
		errChan <- srv.ListenAndServe(ctx)
	}()

	// Wait a bit for it to start
	time.Sleep(100 * time.Millisecond)
	cancel()

	select {
	case err := <-errChan:
		if err != nil {
			t.Errorf("ListenAndServe failed: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Error("timed out waiting for ListenAndServe to stop")
	}
}
