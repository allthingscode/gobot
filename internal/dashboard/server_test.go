//nolint:testpackage // intentionally tests internals
package dashboard

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestServer_Index(t *testing.T) {
	t.Parallel()
	h := NewHub(10)
	defer h.Close()
	s := NewServer(h, "127.0.0.1:0")

	req := httptest.NewRequest("GET", "/", http.NoBody) //nolint:noctx // test request
	w := httptest.NewRecorder()
	s.handleIndex(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", w.Code)
	}
	if w.Header().Get("Content-Type") != "text/html" {
		t.Errorf("expected text/html, got %s", w.Header().Get("Content-Type"))
	}
}

func TestServer_Events(t *testing.T) {
	t.Parallel()
	h := NewHub(10)
	defer h.Close()
	s := NewServer(h, "127.0.0.1:0")

	h.Emit(&LogEntry{Message: "buffered"})

	req := httptest.NewRequest("GET", "/events", http.NoBody) //nolint:noctx // test request
	ctx, cancel := context.WithCancel(req.Context())
	req = req.WithContext(ctx)

	// Use a real ResponseWriter that supports Flushing if possible, 
	// but httptest.ResponseRecorder supports it in newer Go versions.
	w := httptest.NewRecorder()

	go func() {
		time.Sleep(100 * time.Millisecond)
		h.Emit(&LogEntry{Message: "live"})
		time.Sleep(100 * time.Millisecond)
		cancel()
	}()

	s.handleEvents(w, req)

	body := w.Body.String()
	if body == "" {
		t.Error("expected non-empty body")
	}
	// Check for SSE format
	if !contains(body, "data: {") {
		t.Error("expected data: { in body")
	}
	if !contains(body, "buffered") {
		t.Error("expected 'buffered' in body")
	}
	if !contains(body, "live") {
		t.Error("expected 'live' in body")
	}
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || s[0:len(substr)] == substr || contains(s[1:], substr))
}
