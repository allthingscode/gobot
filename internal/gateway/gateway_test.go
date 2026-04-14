//nolint:testpackage // requires unexported gateway internals for testing
package gateway

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/gateway/dash"
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
	srv := NewServer(cfg, h, dash.Resources{})

	t.Run("Health", func(t *testing.T) {
		t.Parallel()
		validateHealth(t, srv)
	})

	t.Run("Chat", func(t *testing.T) {
		t.Parallel()
		localH := &mockHandler{}
		localSrv := NewServer(cfg, localH, dash.Resources{})
		validateChat(t, localSrv, localH, "test-session", "hello gateway", "Reply: hello gateway")
	})
	t.Run("Chat_DefaultSession", func(t *testing.T) {
		t.Parallel()
		validateChat(t, srv, h, "", "no session", "")
	})

	t.Run("InvalidMethod", func(t *testing.T) {
		t.Parallel()
		validateChatError(t, srv, "GET", "/chat", http.NoBody, http.StatusMethodNotAllowed)
	})

	t.Run("InvalidJSON", func(t *testing.T) {
		t.Parallel()
		validateChatError(t, srv, "POST", "/chat", bytes.NewReader([]byte("not json")), http.StatusBadRequest)
	})

	t.Run("HandlerError", func(t *testing.T) {
		t.Parallel()
		hErr := &mockHandler{err: true}
		srvErr := NewServer(cfg, hErr, dash.Resources{})
		validateChatHandlerError(t, srvErr, "fail", "mock error")
	})
}

func validateHealth(t *testing.T, srv *Server) {
	t.Helper()
	req := httptest.NewRequestWithContext(context.Background(), "GET", "/health", http.NoBody)
	w := httptest.NewRecorder()
	srv.handleHealth(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", w.Code)
	}
	if w.Body.String() != "OK" {
		t.Errorf("expected OK, got %q", w.Body.String())
	}
}

func validateChat(t *testing.T, srv *Server, h *mockHandler, session, text, expectedReply string) {
	t.Helper()
	in := InboundRequest{
		SessionKey: session,
		Text:       text,
	}
	body, _ := json.Marshal(in) // nolint:gosec // SessionKey is not a secret
	req := httptest.NewRequestWithContext(context.Background(), "POST", "/chat", bytes.NewReader(body))
	w := httptest.NewRecorder()
	srv.handleChat(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", w.Code)
	}

	if expectedReply != "" {
		var resp OutboundResponse
		if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
			t.Fatalf("failed to decode response: %v", err)
		}

		if resp.Reply != expectedReply {
			t.Errorf("unexpected reply: %q", resp.Reply)
		}
		if h.lastMsg != text {
			t.Errorf("handler did not receive correct message: %q", h.lastMsg)
		}
	}
}

func validateChatError(t *testing.T, srv *Server, method, path string, body io.Reader, expectedStatus int) {
	t.Helper()
	req := httptest.NewRequestWithContext(context.Background(), method, path, body)
	w := httptest.NewRecorder()
	srv.handleChat(w, req)

	if w.Code != expectedStatus {
		t.Errorf("expected %d, got %d", expectedStatus, w.Code)
	}
}

func validateChatHandlerError(t *testing.T, srv *Server, text, expectedError string) {
	t.Helper()
	in := InboundRequest{Text: text}
	body, _ := json.Marshal(in) // nolint:gosec // SessionKey is not a secret
	req := httptest.NewRequestWithContext(context.Background(), "POST", "/chat", bytes.NewReader(body))
	w := httptest.NewRecorder()
	srv.handleChat(w, req)

	var resp OutboundResponse
	_ = json.NewDecoder(w.Body).Decode(&resp)
	if resp.Error != expectedError {
		t.Errorf("expected %s, got %q", expectedError, resp.Error)
	}
}

func TestGateway_ListenAndServe(t *testing.T) {
	t.Parallel()
	cfg := config.GatewayConfig{Host: "localhost", Port: 0}
	h := &mockHandler{}
	srv := NewServer(cfg, h, dash.Resources{})

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
