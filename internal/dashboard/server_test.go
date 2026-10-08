//nolint:testpackage // intentionally tests internals
package dashboard

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// flushedEventsRecorder is read and written only by the handler until it exits.
type flushedEventsRecorder struct {
	*httptest.ResponseRecorder
	buffered     chan struct{}
	live         chan struct{}
	bufferedOnce sync.Once
	liveOnce     sync.Once
}

func (w *flushedEventsRecorder) Flush() {
	w.ResponseRecorder.Flush()
	frames := strings.Split(w.Body.String(), "\n\n")
	// The last segment may be incomplete, so only inspect terminated frames.
	for _, frame := range frames[:len(frames)-1] {
		if !strings.HasPrefix(frame, "data: {") {
			continue
		}
		if strings.Contains(frame, `"message":"buffered"`) {
			w.bufferedOnce.Do(func() { close(w.buffered) })
		}
		if strings.Contains(frame, `"message":"live"`) {
			w.liveOnce.Do(func() { close(w.live) })
		}
	}
}

func streamTestEvents(t *testing.T, h *Hub, req *http.Request, handler http.HandlerFunc) *httptest.ResponseRecorder {
	t.Helper()
	ctx, cancel := context.WithCancel(req.Context())
	w := &flushedEventsRecorder{
		ResponseRecorder: httptest.NewRecorder(),
		buffered:         make(chan struct{}),
		live:             make(chan struct{}),
	}
	done := make(chan struct{})
	// Cancel and join even when a delivery wait calls Fatal. Close the hub only
	// after joining; never inspect the recorder on a cleanup timeout.
	t.Cleanup(func() {
		cancel()
		select {
		case <-done:
			h.Close()
		case <-time.After(5 * time.Second):
			t.Error("timed out joining SSE handler during cleanup")
		}
	})
	go func() {
		defer close(done)
		handler(w, req.WithContext(ctx))
	}()

	waitForFlush := func(signal <-chan struct{}, message string) {
		t.Helper()
		select {
		case <-done:
			t.Fatalf("SSE handler exited before observing %s flush", message)
		case <-signal:
			// A flush and premature exit may both be ready.
			select {
			case <-done:
				t.Fatalf("SSE handler exited while observing %s flush", message)
			default:
			}
		case <-time.After(5 * time.Second):
			t.Fatalf("timed out waiting for %s SSE flush", message)
		}
	}
	waitForFlush(w.buffered, "buffered")
	h.Emit(&LogEntry{Message: "live"})
	waitForFlush(w.live, "live")
	cancel()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("timed out joining SSE handler after cancellation")
	}
	return w.ResponseRecorder
}

func TestServer_Index(t *testing.T) {
	t.Parallel()
	h := NewHub(10)
	defer h.Close()
	s := NewServer(h, "127.0.0.1:0", "")

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
	s := NewServer(h, "127.0.0.1:0", "")

	h.Emit(&LogEntry{Message: "buffered"})

	req := httptest.NewRequest("GET", "/events", http.NoBody) //nolint:noctx // test request
	w := streamTestEvents(t, h, req, s.handleEvents)

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

func TestServer_Auth_RejectsWithoutToken(t *testing.T) {
	t.Parallel()
	h := NewHub(10)
	defer h.Close()
	s := NewServer(h, "127.0.0.1:0", "secret")

	req := httptest.NewRequest("GET", "/events", http.NoBody) //nolint:noctx // test request
	w := httptest.NewRecorder()
	s.handler().ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("expected 401 without token, got %d", w.Code)
	}
}

func TestServer_Auth_AllowsWithToken(t *testing.T) {
	t.Parallel()
	h := NewHub(10)
	s := NewServer(h, "127.0.0.1:0", "secret")

	h.Emit(&LogEntry{Message: "buffered"})

	req := httptest.NewRequest("GET", "/events?token=secret", http.NoBody) //nolint:noctx // test request
	w := streamTestEvents(t, h, req, s.handler().ServeHTTP)

	if w.Code != http.StatusOK {
		t.Errorf("expected 200 with valid token, got %d", w.Code)
	}
	body := w.Body.String()
	if !contains(body, "buffered") || !contains(body, "live") {
		t.Errorf("expected streamed events in body, got %q", body)
	}
}

func TestServer_NoWildcardCORS(t *testing.T) {
	t.Parallel()
	h := NewHub(10)
	defer h.Close()
	s := NewServer(h, "127.0.0.1:0", "")

	req := httptest.NewRequest("GET", "/events", http.NoBody) //nolint:noctx // test request
	ctx, cancel := context.WithCancel(req.Context())
	req = req.WithContext(ctx)
	w := httptest.NewRecorder()

	go func() {
		time.Sleep(50 * time.Millisecond)
		cancel()
	}()

	s.handler().ServeHTTP(w, req)

	if got := w.Header().Get("Access-Control-Allow-Origin"); got != "" {
		t.Errorf("expected no Access-Control-Allow-Origin header, got %q", got)
	}
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || s[0:len(substr)] == substr || contains(s[1:], substr))
}
