//nolint:testpackage // requires unexported bot internals for testing
package bot

import (
	"context"
	"errors"
	"io"
	"runtime"
	"sync"
	"testing"
	"time"

	"github.com/google/go-cmp/cmp"
	"github.com/stretchr/testify/assert"
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
	lastUpdate   time.Time
	lastCallback time.Time
	delays       []time.Duration
	mu           sync.Mutex
}

func (m *mockAPIWithCircuit) Updates(_ context.Context, _ int) (<-chan InboundMessage, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := time.Now()
	if !m.lastUpdate.IsZero() {
		m.delays = append(m.delays, now.Sub(m.lastUpdate))
	}
	m.lastUpdate = now
	return nil, errors.New("circuit breaker: open")
}

func (m *mockAPIWithCircuit) Callbacks(_ context.Context) (<-chan InboundCallback, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := time.Now()
	if !m.lastCallback.IsZero() {
		m.delays = append(m.delays, now.Sub(m.lastCallback))
	}
	m.lastCallback = now
	return nil, errors.New("circuit breaker: open")
}
func (m *mockAPIWithCircuit) Send(_ context.Context, _ OutboundMessage) error { return nil }
func (m *mockAPIWithCircuit) SendWithButtons(_ context.Context, _ OutboundMessage, _ [][]Button) error {
	return nil
}

func (m *mockAPIWithCircuit) Typing(_ context.Context, _, _ int64) func() {
	return func() {}
}
func (m *mockAPIWithCircuit) Stop() {}

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
	t.Parallel()
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
			t.Parallel()
			got := SessionKey(tt.chatID, tt.threadID, tt.senderID)
			assert.Equal(t, tt.want, got, "SessionKey(%d, %d, %d)", tt.chatID, tt.threadID, tt.senderID)
		})
	}
}

func TestSessionKey_GroupIsolation(t *testing.T) {
	t.Parallel()
	// Two different senders in the same group must get different session keys.
	key1 := SessionKey(-1001234567890, 0, 100)
	key2 := SessionKey(-1001234567890, 0, 200)
	if key1 == key2 {
		t.Errorf("users 100 and 200 in same group got identical session keys: %q", key1)
	}
}

func TestSessionKey_DMNotDoubled(t *testing.T) {
	t.Parallel()
	// DM: chatID == senderID — must not produce "telegram:12345:12345".
	key := SessionKey(12345, 0, 12345)
	if key != "telegram:12345" {
		t.Errorf("DM session key = %q, want %q", key, "telegram:12345")
	}
}

func TestIsTransientError(t *testing.T) {
	t.Parallel()
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
		{"no choices returned", errors.New("openrouter: no choices returned"), true},
		{"invalid token", errors.New("invalid token"), false},
		{"unauthorized", errors.New("unauthorized"), false},
		{"bad request", errors.New("bad request"), false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got := IsTransientError(tt.err)
			assert.Equal(t, tt.want, got, "IsTransientError(%v)", tt.err)
		})
	}
}

func TestInboundMessage_Validate(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name    string
		msg     InboundMessage
		wantErr bool
		errText string
	}{
		{
			name:    "valid DM",
			msg:     InboundMessage{ChatID: 123, SenderID: 123, Text: "hi"},
			wantErr: false,
		},
		{
			name:    "valid group",
			msg:     InboundMessage{ChatID: -100123, SenderID: 456, Text: "hi"},
			wantErr: false,
		},
		{
			name:    "missing ChatID",
			msg:     InboundMessage{ChatID: 0, SenderID: 123, Text: "hi"},
			wantErr: true,
			errText: "missing ChatID",
		},
		{
			name:    "missing SenderID",
			msg:     InboundMessage{ChatID: 123, SenderID: 0, Text: "hi"},
			wantErr: true,
			errText: "missing SenderID",
		},
		{
			name:    "negative ThreadID",
			msg:     InboundMessage{ChatID: 123, SenderID: 123, ThreadID: -1, Text: "hi"},
			wantErr: true,
			errText: "negative ThreadID",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			err := tt.msg.Validate()
			if tt.wantErr {
				assert.Error(t, err)
				if tt.errText != "" {
					assert.Contains(t, err.Error(), tt.errText)
				}
			} else {
				assert.NoError(t, err)
			}
		})
	}
}

func TestBot_Run_DispatchesMessages(t *testing.T) {
	t.Parallel()
	api := newMockAPI(
		InboundMessage{ChatID: 1, MessageID: 10, SenderID: 100, Text: "hello"},
		InboundMessage{ChatID: 2, MessageID: 20, SenderID: 200, Text: "world"},
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

	_ = bot.Run(ctx)

	calls := handler.getCalls()
	assert.Len(t, calls, 2, "handler calls")
	assert.Contains(t, calls, "telegram:1")
	assert.Contains(t, calls, "telegram:2")

	sent := api.getSent()
	assert.Len(t, sent, 2, "sent messages")
	// Extract chat IDs for easier comparison.
	chatIDs := make([]int64, 0, len(sent))
	for _, s := range sent {
		chatIDs = append(chatIDs, s.ChatID)
	}
	assert.Contains(t, chatIDs, int64(1))
	assert.Contains(t, chatIDs, int64(2))
}

func TestBot_Run_NoReplyForEmptyResponse(t *testing.T) {
	t.Parallel()
	api := newMockAPI(InboundMessage{ChatID: 1, SenderID: 100, Text: "hi"})
	handler := &mockHandler{response: ""} // empty = no reply
	bot := New(api, handler)

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(20 * time.Millisecond)
		close(api.updates)
		time.Sleep(10 * time.Millisecond)
		cancel()
	}()
	_ = bot.Run(ctx)

	if sent := api.getSent(); len(sent) != 0 {
		t.Errorf("expected no sends for empty response, got %d", len(sent))
	}
}

func TestBot_Run_HandlerErrorDoesNotStop(t *testing.T) {
	t.Parallel()
	api := newMockAPI(
		InboundMessage{ChatID: 1, SenderID: 100, Text: "first"},
		InboundMessage{ChatID: 2, SenderID: 200, Text: "second"},
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
	_ = bot.Run(ctx)

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
	t.Parallel()
	fallback := newMockAPI(InboundMessage{ChatID: 99, SenderID: 999, Text: "retry-msg"})
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

	_ = bot.Run(ctx)

	if calls := handler.getCalls(); len(calls) == 0 {
		t.Error("expected at least one handler call after retry")
	}
}

func TestBot_Run_ContextCancellation(t *testing.T) {
	t.Parallel()
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
	t.Parallel()
	api := newMockAPI()
	bot := New(api, &mockHandler{})

	msg := OutboundMessage{ChatID: 42, ThreadID: 7, Text: "hello"}
	if err := bot.Send(context.Background(), msg); err != nil {
		t.Fatalf("Send failed: %v", err)
	}
	sent := api.getSent()
	assert.Len(t, sent, 1, "sent messages")
	if diff := cmp.Diff(msg, sent[0]); diff != "" {
		t.Errorf("sent message mismatch (-want +got):\n%s", diff)
	}
}

func TestBot_Run_ThreadAwareSessionKey(t *testing.T) {
	t.Parallel()
	api := newMockAPI(InboundMessage{ChatID: 500, ThreadID: 12, SenderID: 100, Text: "topic msg"})
	handler := &mockHandler{response: ""}
	bot := New(api, handler)

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(20 * time.Millisecond)
		close(api.updates)
		time.Sleep(10 * time.Millisecond)
		cancel()
	}()
	_ = bot.Run(ctx)

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
	t.Parallel()
	api := &mockAPIWithCircuit{}
	bot := New(api, &mockHandler{})

	// Context that cancels quickly after a couple of retries would take.
	// Since initial delay is 5s, we'll wait 6s to see at least one retry gap.
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()

	start := time.Now()
	_ = bot.Run(ctx)
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

type blockingHandler struct {
	started chan struct{}
	block   chan struct{}
}

func (h *blockingHandler) HandleCallback(ctx context.Context, cb InboundCallback) error {
	close(h.started)
	<-h.block // Block indefinitely until test allows
	return nil
}

func (h *blockingHandler) Handle(ctx context.Context, sessionKey string, msg InboundMessage) (string, error) {
	return "", nil
}

//nolint:paralleltest // relies on runtime.NumGoroutine() (process-wide); running alongside
// long-lived parallel bot tests causes spurious goroutine count increases.
func TestBot_CallbackLeakPrevention(t *testing.T) {
	// Custom API to feed exactly one callback and then block indefinitely
	api := &mockAPI{
		updates:   make(chan InboundMessage),
		callbacks: make(chan InboundCallback, 1),
	}

	api.callbacks <- InboundCallback{ChatID: 100, SessionKey: "sess_1", Data: "data"}

	handler := &blockingHandler{
		started: make(chan struct{}),
		block:   make(chan struct{}),
	}
	bot := New(api, handler)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Capture initial goroutines
	time.Sleep(10 * time.Millisecond)
	initialGoroutines := runtime.NumGoroutine()

	done := make(chan struct{})
	go func() {
		_ = bot.Run(ctx)
		close(done)
	}()

	// Wait for handler to actually start processing the callback
	select {
	case <-handler.started:
	case <-time.After(2 * time.Second):
		t.Fatal("handler did not start")
	}

	// At this point, the callback is blocking. Cancel the bot context.
	cancel()

	// Wait for Run to return
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("bot did not shut down after context cancellation")
	}

	// Wait a brief moment for goroutines to drain
	time.Sleep(50 * time.Millisecond)

	finalGoroutines := runtime.NumGoroutine()

	// Unblock to avoid polluting other tests
	close(handler.block)

	if finalGoroutines > initialGoroutines+2 {
		t.Errorf("goroutine leak: started with %d, ended with %d", initialGoroutines, finalGoroutines)
	}
}

func TestBot_Run_DropsInvalidMessages(t *testing.T) {
	t.Parallel()
	api := newMockAPI(
		InboundMessage{ChatID: 0, SenderID: 123, Text: "missing chat"},
		InboundMessage{ChatID: 123, SenderID: 0, Text: "missing sender"},
		InboundMessage{ChatID: 123, SenderID: 123, ThreadID: -1, Text: "bad thread"},
		InboundMessage{ChatID: 123, SenderID: 123, Text: "valid"},
	)
	handler := &mockHandler{response: "ok"}
	bot := New(api, handler)

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(100 * time.Millisecond)
		close(api.updates)
		time.Sleep(50 * time.Millisecond)
		cancel()
	}()
	_ = bot.Run(ctx)

	calls := handler.getCalls()
	assert.Len(t, calls, 1, "only valid message should reach handler")
	if len(calls) > 0 {
		assert.Equal(t, "telegram:123", calls[0])
	}
}
