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
	updates   chan InboundMessage
	callbacks chan InboundCallback
	sent      []OutboundMessage
	sendErr   error
	stopped   bool
	mu        sync.Mutex
}

func newMockAPI(msgs ...InboundMessage) *mockAPI {
	m := &mockAPI{
		updates:   make(chan InboundMessage, len(msgs)+10),
		callbacks: make(chan InboundCallback, 10),
	}
	for _, msg := range msgs {
		m.updates <- msg
	}
	return m
}

func (m *mockAPI) Updates(_ context.Context, _ int) (<-chan InboundMessage, error) {
	return m.updates, nil
}

func (m *mockAPI) Callbacks(_ context.Context) (<-chan InboundCallback, error) {
	return m.callbacks, nil
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

func (m *mockAPI) SendWithButtons(_ context.Context, msg OutboundMessage, _ [][]Button) error {
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
func (m *mockAPIWithError) Callbacks(ctx context.Context) (<-chan InboundCallback, error) {
	return m.fallback.Callbacks(ctx)
}
func (m *mockAPIWithError) Send(ctx context.Context, msg OutboundMessage) error {
	return m.fallback.Send(ctx, msg)
}
func (m *mockAPIWithError) SendWithButtons(ctx context.Context, msg OutboundMessage, buttons [][]Button) error {
	return m.fallback.SendWithButtons(ctx, msg, buttons)
}
func (m *mockAPIWithError) Typing(ctx context.Context, chatID, threadID int64) func() {
	return m.fallback.Typing(ctx, chatID, threadID)
}
func (m *mockAPIWithError) Stop() { m.fallback.Stop() }

// mockAPIWithCircuit returns ErrCircuitOpen on Updates/Callbacks.
type mockAPIWithCircuit struct {
	lastCall time.Time
	delays   []time.Duration
	mu       sync.Mutex
}

func (m *mockAPIWithCircuit) Updates(ctx context.Context, timeout int) (<-chan InboundMessage, error) {
	m.recordCall()
	return nil, errors.New("circuit breaker: open")
}
func (m *mockAPIWithCircuit) Callbacks(ctx context.Context) (<-chan InboundCallback, error) {
	m.recordCall()
	return nil, errors.New("circuit breaker: open")
}

func (m *mockAPIWithCircuit) recordCall() {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := time.Now()
	if !m.lastCall.IsZero() {
		m.delays = append(m.delays, now.Sub(m.lastCall))
	}
	m.lastCall = now
}
func (m *mockAPIWithCircuit) Send(ctx context.Context, msg OutboundMessage) error           { return nil }
func (m *mockAPIWithCircuit) SendWithButtons(ctx context.Context, msg OutboundMessage, _ [][]Button) error {
	return nil
}
func (m *mockAPIWithCircuit) Typing(ctx context.Context, chatID, threadID int64) func() { return func() {} }
func (m *mockAPIWithCircuit) Stop()                                                   {}

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

func (h *mockHandler) HandleCallback(_ context.Context, _ InboundCallback) error {
	return nil
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
		senderID int64
		want     string
	}{
		{"DM no thread", 12345, 0, 12345, "telegram:12345"},
		{"DM no thread no sender", 12345, 0, 0, "telegram:12345"},
		{"DM topic thread", 12345, 99, 12345, "telegram:12345:99"},
		{"group with sender", -100123, 0, 456, "telegram:-100123:456"},
		{"group no sender", -100123, 0, 0, "telegram:-100123"},
		{"group two users isolated", -100123, 0, 100, "telegram:-100123:100"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := SessionKey(tt.chatID, tt.threadID, tt.senderID); got != tt.want {
				t.Errorf("SessionKey(%d, %d, %d) = %q, want %q", tt.chatID, tt.threadID, tt.senderID, got, tt.want)
			}
		})
	}
}

func TestSessionKey_GroupIsolation(t *testing.T) {
	// Two different senders in the same group must get different session keys.
	key1 := SessionKey(-1001234567890, 0, 100)
	key2 := SessionKey(-1001234567890, 0, 200)
	if key1 == key2 {
		t.Errorf("users 100 and 200 in same group got identical session keys: %q", key1)
	}
}

func TestSessionKey_DMNotDoubled(t *testing.T) {
	// DM: chatID == senderID — must not produce "telegram:12345:12345".
	key := SessionKey(12345, 0, 12345)
	if key != "telegram:12345" {
		t.Errorf("DM session key = %q, want %q", key, "telegram:12345")
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
		// Wait long enough for goroutines to potentially complete.
		time.Sleep(100 * time.Millisecond)
		close(api.updates)
		time.Sleep(50 * time.Millisecond)
		cancel()
	}()

	bot.Run(ctx)

	calls := handler.getCalls()
	if len(calls) != 2 {
		t.Fatalf("expected 2 handler calls, got %d: %v", len(calls), calls)
	}
	// Check for presence rather than order.
	has1, has2 := false, false
	for _, c := range calls {
		if c == "telegram:1" {
			has1 = true
		}
		if c == "telegram:2" {
			has2 = true
		}
	}
	if !has1 || !has2 {
		t.Errorf("missing expected calls: has1=%v, has2=%v, calls=%v", has1, has2, calls)
	}

	sent := api.getSent()
	if len(sent) != 2 {
		t.Fatalf("expected 2 sends, got %d", len(sent))
	}
	// Check for presence rather than order.
	hasSent1, hasSent2 := false, false
	for _, s := range sent {
		if s.ChatID == 1 {
			hasSent1 = true
		}
		if s.ChatID == 2 {
			hasSent2 = true
		}
	}
	if !hasSent1 || !hasSent2 {
		t.Errorf("missing expected sends: hasSent1=%v, hasSent2=%v, sent=%v", hasSent1, hasSent2, sent)
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
	// Override to return error on one, success on other.
	customHandler := &callCountHandler{
		responses: []string{"", "ok"},
		errs:      []error{errors.New("handler failed"), nil},
	}

	bot := New(api, customHandler)
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		// Wait for goroutines to potentially complete.
		time.Sleep(100 * time.Millisecond)
		close(api.updates)
		time.Sleep(50 * time.Millisecond)
		cancel()
	}()
	bot.Run(ctx)

	if customHandler.callCount() != 2 {
		t.Errorf("expected 2 handler calls, got %d", customHandler.callCount())
	}
	// Exactly one message should have been sent successfully.
	sent := api.getSent()
	if len(sent) != 1 {
		t.Errorf("expected exactly one successful send, got %v", sent)
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

func (h *callCountHandler) HandleCallback(_ context.Context, _ InboundCallback) error {
	return nil
}

func (h *callCountHandler) callCount() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.n
}

func TestBot_Run_BackoffOnCircuitOpen(t *testing.T) {
	api := &mockAPIWithCircuit{}
	bot := New(api, &mockHandler{})

	// Context that cancels quickly after a couple of retries would take.
	// Since initial delay is 5s, we'll wait 6s to see at least one retry gap.
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()

	start := time.Now()
	bot.Run(ctx)
	elapsed := time.Since(start)

	if elapsed < 5*time.Second {
		t.Errorf("Bot.Run exited too early: %v, expected it to wait for backoff (at least 5s)", elapsed)
	}

	api.mu.Lock()
	delays := api.delays
	api.mu.Unlock()

	// We expect at least one delay recorded (between 1st and 2nd attempt).
	if len(delays) == 0 {
		t.Error("expected at least one retry attempt with delay")
	}
	for i, d := range delays {
		if d < 4*time.Second { // Allow some slack from 5s
			t.Errorf("delay %d was too short: %v, want ~5s", i, d)
		}
	}
}
