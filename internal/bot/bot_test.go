package bot

import (
	"context"
	"errors"
	"io"
	"sync"
	"testing"
	"time"
)

// ── Mock API ──────────────────────────────────────────────────────────────────

type mockAPI struct {
	updates chan InboundMessage
	sent    []OutboundMessage
	sendErr error
	stopped bool
	mu      sync.Mutex
}

func newMockAPI(msgs ...InboundMessage) *mockAPI {
	m := &mockAPI{updates: make(chan InboundMessage, len(msgs))}
	for _, msg := range msgs {
		m.updates <- msg
	}
	return m
}

func (m *mockAPI) Updates(_ context.Context, _ int) (<-chan InboundMessage, error) {
	return m.updates, nil
}

func (m *mockAPI) Send(_ context.Context, msg OutboundMessage) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.sendErr != nil {
		return m.sendErr
	}
	m.sent = append(m.sent, msg)
	return nil
}

func (m *mockAPI) Typing(_ context.Context, _, _ int64) func() {
	return func() {}
}

func (m *mockAPI) Stop() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.stopped = true
}

func (m *mockAPI) getSent() []OutboundMessage {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]OutboundMessage, len(m.sent))
	copy(out, m.sent)
	return out
}

// mockAPIWithError returns an error on the first Updates call, then succeeds.
type mockAPIWithError struct {
	attempt  int
	fallback *mockAPI
	mu       sync.Mutex
}

func (m *mockAPIWithError) Updates(ctx context.Context, timeout int) (<-chan InboundMessage, error) {
	m.mu.Lock()
	attempt := m.attempt
	m.attempt++
	m.mu.Unlock()
	if attempt == 0 {
		return nil, errors.New("ReadError: connection timeout")
	}
	return m.fallback.Updates(ctx, timeout)
}
func (m *mockAPIWithError) Send(ctx context.Context, msg OutboundMessage) error {
	return m.fallback.Send(ctx, msg)
}
func (m *mockAPIWithError) Typing(ctx context.Context, chatID, threadID int64) func() {
	return m.fallback.Typing(ctx, chatID, threadID)
}
func (m *mockAPIWithError) Stop() { m.fallback.Stop() }

// ── Mock Handler ──────────────────────────────────────────────────────────────

type mockHandler struct {
	response string
	err      error
	calls    []string
	mu       sync.Mutex
}

func (h *mockHandler) Handle(_ context.Context, sessionKey string, _ InboundMessage) (string, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.calls = append(h.calls, sessionKey)
	return h.response, h.err
}

func (h *mockHandler) getCalls() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	out := make([]string, len(h.calls))
	copy(out, h.calls)
	return out
}

// ── Tests ─────────────────────────────────────────────────────────────────────

func TestSessionKey(t *testing.T) {
	tests := []struct {
		name     string
		chatID   int64
		threadID int64
		want     string
	}{
		{"DM no thread", 12345, 0, "telegram:12345"},
		{"topic thread", 12345, 99, "telegram:12345:99"},
		{"group chat", -100123, 0, "telegram:-100123"},
		{"group topic", -100123, 5, "telegram:-100123:5"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := SessionKey(tt.chatID, tt.threadID); got != tt.want {
				t.Errorf("SessionKey(%d, %d) = %q, want %q", tt.chatID, tt.threadID, got, tt.want)
			}
		})
	}
}

func TestIsTransientError(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want bool
	}{
		{"nil", nil, false},
		{"ReadError", errors.New("ReadError: connection failed"), true},
		{"timed out", errors.New("timed out waiting for response"), true},
		{"connection reset by peer", errors.New("connection reset by peer"), true},
		{"connection reset", errors.New("connection reset"), true},
		{"network error", errors.New("network unreachable"), true},
		{"RemoteProtocolError", errors.New("RemoteProtocolError"), true},
		{"io.EOF", io.EOF, true},
		{"DeadlineExceeded", context.DeadlineExceeded, true},
		{"invalid token", errors.New("invalid token"), false},
		{"unauthorized", errors.New("unauthorized"), false},
		{"bad request", errors.New("bad request"), false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := IsTransientError(tt.err); got != tt.want {
				t.Errorf("IsTransientError(%v) = %v, want %v", tt.err, got, tt.want)
			}
		})
	}
}

func TestBot_Run_DispatchesMessages(t *testing.T) {
	api := newMockAPI(
		InboundMessage{ChatID: 1, MessageID: 10, Text: "hello"},
		InboundMessage{ChatID: 2, MessageID: 20, Text: "world"},
	)
	handler := &mockHandler{response: "reply"}
	bot := New(api, handler)

	ctx, cancel := context.WithCancel(context.Background())

	// Close the updates channel so Run exits the drain loop, then cancel ctx.
	go func() {
		time.Sleep(20 * time.Millisecond)
		close(api.updates)
		time.Sleep(20 * time.Millisecond)
		cancel()
	}()

	bot.Run(ctx)

	calls := handler.getCalls()
	if len(calls) != 2 {
		t.Fatalf("expected 2 handler calls, got %d: %v", len(calls), calls)
	}
	if calls[0] != "telegram:1" {
		t.Errorf("call[0] = %q, want %q", calls[0], "telegram:1")
	}
	if calls[1] != "telegram:2" {
		t.Errorf("call[1] = %q, want %q", calls[1], "telegram:2")
	}

	sent := api.getSent()
	if len(sent) != 2 {
		t.Fatalf("expected 2 sends, got %d", len(sent))
	}
	if sent[0].ChatID != 1 || sent[1].ChatID != 2 {
		t.Errorf("unexpected send chat IDs: %v", sent)
	}
}

func TestBot_Run_NoReplyForEmptyResponse(t *testing.T) {
	api := newMockAPI(InboundMessage{ChatID: 1, Text: "hi"})
	handler := &mockHandler{response: ""} // empty = no reply
	bot := New(api, handler)

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(20 * time.Millisecond)
		close(api.updates)
		time.Sleep(10 * time.Millisecond)
		cancel()
	}()
	bot.Run(ctx)

	if sent := api.getSent(); len(sent) != 0 {
		t.Errorf("expected no sends for empty response, got %d", len(sent))
	}
}

func TestBot_Run_HandlerErrorDoesNotStop(t *testing.T) {
	api := newMockAPI(
		InboundMessage{ChatID: 1, Text: "first"},
		InboundMessage{ChatID: 2, Text: "second"},
	)
	// Override to return error on first, success on second.
	customHandler := &callCountHandler{
		responses: []string{"", "ok"},
		errs:      []error{errors.New("handler failed"), nil},
	}

	bot := New(api, customHandler)
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(30 * time.Millisecond)
		close(api.updates)
		time.Sleep(10 * time.Millisecond)
		cancel()
	}()
	bot.Run(ctx)

	if customHandler.callCount() != 2 {
		t.Errorf("expected 2 handler calls, got %d", customHandler.callCount())
	}
	// Second message should have been sent successfully.
	if sent := api.getSent(); len(sent) != 1 || sent[0].ChatID != 2 {
		t.Errorf("expected one send for chatID=2, got %v", sent)
	}
}

func TestBot_Run_RetriesOnTransientError(t *testing.T) {
	fallback := newMockAPI(InboundMessage{ChatID: 99, Text: "retry-msg"})
	api := &mockAPIWithError{fallback: fallback}
	handler := &mockHandler{response: "ok"}
	bot := New(api, handler)

	// Override retry delay via a short-timeout context to avoid 5s wait.
	// We'll use a subtest that cancels quickly if retry doesn't happen.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	go func() {
		// Wait for the message to be processed, then close and cancel.
		for {
			time.Sleep(50 * time.Millisecond)
			if len(handler.getCalls()) >= 1 {
				close(fallback.updates)
				time.Sleep(10 * time.Millisecond)
				cancel()
				return
			}
		}
	}()

	bot.Run(ctx)

	if calls := handler.getCalls(); len(calls) == 0 {
		t.Error("expected at least one handler call after retry")
	}
}

func TestBot_Run_ContextCancellation(t *testing.T) {
	api := newMockAPI() // no messages
	handler := &mockHandler{}
	bot := New(api, handler)

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // cancel immediately

	err := bot.Run(ctx)
	if !errors.Is(err, context.Canceled) {
		t.Errorf("Run() = %v, want context.Canceled", err)
	}
}

func TestBot_Send(t *testing.T) {
	api := newMockAPI()
	bot := New(api, &mockHandler{})

	msg := OutboundMessage{ChatID: 42, ThreadID: 7, Text: "hello"}
	if err := bot.Send(context.Background(), msg); err != nil {
		t.Fatalf("Send failed: %v", err)
	}
	sent := api.getSent()
	if len(sent) != 1 {
		t.Fatalf("expected 1 sent message, got %d", len(sent))
	}
	if sent[0] != msg {
		t.Errorf("sent = %+v, want %+v", sent[0], msg)
	}
}

func TestBot_Run_ThreadAwareSessionKey(t *testing.T) {
	api := newMockAPI(InboundMessage{ChatID: 500, ThreadID: 12, Text: "topic msg"})
	handler := &mockHandler{response: ""}
	bot := New(api, handler)

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(20 * time.Millisecond)
		close(api.updates)
		time.Sleep(10 * time.Millisecond)
		cancel()
	}()
	bot.Run(ctx)

	calls := handler.getCalls()
	if len(calls) != 1 || calls[0] != "telegram:500:12" {
		t.Errorf("session key = %v, want [telegram:500:12]", calls)
	}
}

// ── Helper types ──────────────────────────────────────────────────────────────

type callCountHandler struct {
	responses []string
	errs      []error
	n         int
	mu        sync.Mutex
}

func (h *callCountHandler) Handle(_ context.Context, _ string, _ InboundMessage) (string, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	i := h.n
	h.n++
	if i < len(h.responses) {
		return h.responses[i], h.errs[i]
	}
	return "", nil
}

func (h *callCountHandler) callCount() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.n
}
