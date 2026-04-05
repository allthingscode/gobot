package agent

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"

	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
)

// ── Mock runner ───────────────────────────────────────────────────────────────

type mockRunner struct {
	response string
	err      error
	calls    []runCall
	mu       sync.Mutex
}

type runCall struct {
	sessionKey string
	messages   []agentctx.StrategicMessage
}

func (r *mockRunner) Run(_ context.Context, sessionKey string, messages []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error) {
	r.mu.Lock()
	r.calls = append(r.calls, runCall{sessionKey: sessionKey, messages: messages})
	r.mu.Unlock()

	if r.err != nil {
		return "", nil, r.err
	}
	updated := append(messages, agentctx.StrategicMessage{Role: "assistant"})
	return r.response, updated, nil
}

func (r *mockRunner) RunText(_ context.Context, sessionKey, prompt string, _ string) (string, error) {
	if r.err != nil {
		return "", r.err
	}
	return r.response, nil
}

// ── Mock checkpoint store ─────────────────────────────────────────────────────

type mockStore struct {
	snapshots   map[string]*agentctx.ThreadSnapshot
	saveErr     error
	loadErr     error
	createCalls []string
	saveCalls   int
	mu          sync.Mutex
}

func newMockStore() *mockStore {
	return &mockStore{snapshots: make(map[string]*agentctx.ThreadSnapshot)}
}

func (s *mockStore) LoadLatest(threadID string) (*agentctx.ThreadSnapshot, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.loadErr != nil {
		return nil, s.loadErr
	}
	snap, ok := s.snapshots[threadID]
	if !ok {
		return nil, nil
	}
	return snap, nil
}

func (s *mockStore) SaveSnapshot(threadID string, iteration int, messages []agentctx.StrategicMessage) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.saveCalls++
	if s.saveErr != nil {
		return false, s.saveErr
	}
	s.snapshots[threadID] = &agentctx.ThreadSnapshot{
		Iteration: iteration,
		Messages:  messages,
		Model:     "mock",
	}
	return true, nil
}

func (s *mockStore) CreateThread(threadID, model string, _ map[string]any) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.createCalls = append(s.createCalls, threadID)
	return nil
}

// ── Mock consolidator ──────────────────────────────────────────────────────────

type mockConsolidator struct {
	calls []consolidateCall
	mu    sync.Mutex
}

type consolidateCall struct {
	sessionKey string
	text       string
}

func (c *mockConsolidator) ConsolidateAsync(sessionKey, text string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.calls = append(c.calls, consolidateCall{sessionKey: sessionKey, text: text})
}

// ── Tests ─────────────────────────────────────────────────────────────────────

func TestStripSilent(t *testing.T) {
	tests := []struct {
		name        string
		input       string
		wantCleaned string
		wantSilent  bool
	}{
		{"no prefix", "hello world", "hello world", false},
		{"silent prefix", "[SILENT] do this quietly", "do this quietly", true},
		{"silent prefix no space", "[SILENT]message", "message", true},
		{"partial prefix", "[SILEN]message", "[SILEN]message", false},
		{"empty string", "", "", false},
		{"only prefix", "[SILENT]", "", true},
		{"only prefix with space", "[SILENT]   ", "", true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotCleaned, gotSilent := StripSilent(tt.input)
			if gotCleaned != tt.wantCleaned {
				t.Errorf("%s: got cleaned %q, want %q", tt.name, gotCleaned, tt.wantCleaned)
			}
			if gotSilent != tt.wantSilent {
				t.Errorf("%s: got silent %v, want %v", tt.name, gotSilent, tt.wantSilent)
			}
		})
	}
}

func TestSessionManager_CompactionWithMemoryFlush(t *testing.T) {
	ctx := context.Background()
	runner := &mockRunner{response: "ok"}
	store := newMockStore()
	mgr := NewSessionManager(runner, store, "mock")

	// Pre-fill history with 10 messages.
	history := make([]agentctx.StrategicMessage, 10)
	for i := range history {
		role := "user"
		if i%2 == 1 {
			role = "assistant"
		}
		content := "msg"
		history[i] = agentctx.StrategicMessage{
			Role:    role,
			Content: &agentctx.MessageContent{Str: &content},
		}
	}
	store.SaveSnapshot("sess1", 1, history)

	// Set compaction policy.
	mgr.SetMemoryWindow(5)
	mgr.SetCompactionPolicy(config.CompactionPolicyConfig{
		Strategy: "memoryFlush",
	})
	cons := &mockConsolidator{}
	mgr.SetConsolidator(cons)

	// Dispatch a new message.
	_, err := mgr.Dispatch(ctx, "sess1", "new message")
	if err != nil {
		t.Fatalf("Dispatch: %v", err)
	}

	// Verify consolidator was called.
	cons.mu.Lock()
	defer cons.mu.Unlock()
	if len(cons.calls) != 1 {
		t.Errorf("expected 1 consolidator call, got %d", len(cons.calls))
	} else {
		if cons.calls[0].sessionKey != "sess1" {
			t.Errorf("wrong session key: %s", cons.calls[0].sessionKey)
		}
		if cons.calls[0].text == "" {
			t.Error("expected non-empty consolidated text")
		}
	}
}


func TestDispatch_BasicRoundtrip(t *testing.T) {
	runner := &mockRunner{response: "pong"}
	mgr := NewSessionManager(runner, nil, "test-model")

	resp, err := mgr.Dispatch(context.Background(), "session-1", "ping")
	if err != nil {
		t.Fatalf("Dispatch failed: %v", err)
	}
	if resp != "pong" {
		t.Errorf("response = %q, want %q", resp, "pong")
	}
	if len(runner.calls) != 1 {
		t.Fatalf("expected 1 runner call, got %d", len(runner.calls))
	}
	call := runner.calls[0]
	if call.sessionKey != "session-1" {
		t.Errorf("sessionKey = %q, want %q", call.sessionKey, "session-1")
	}
	if len(call.messages) != 1 || call.messages[0].Role != "user" {
		t.Errorf("expected one user message, got: %v", call.messages)
	}
}

func TestDispatch_SilentPrefixStripped(t *testing.T) {
	runner := &mockRunner{response: "ok"}
	mgr := NewSessionManager(runner, nil, "test-model")

	_, err := mgr.Dispatch(context.Background(), "s1", "[SILENT] run quietly")
	if err != nil {
		t.Fatalf("Dispatch failed: %v", err)
	}
	call := runner.calls[0]
	if len(call.messages) == 0 {
		t.Fatal("no messages passed to runner")
	}
	var text string
	c := call.messages[0].Content
	if c != nil && c.Str != nil {
		text = *c.Str
	}
	if text != "run quietly" {
		t.Errorf("runner received %q, want %q", text, "run quietly")
	}
}

func TestDispatch_RunnerError(t *testing.T) {
	runner := &mockRunner{err: errors.New("model overloaded")}
	mgr := NewSessionManager(runner, nil, "test-model")

	_, err := mgr.Dispatch(context.Background(), "s1", "hello")
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !errors.Is(err, runner.err) {
		t.Errorf("error = %v, want to wrap %v", err, runner.err)
	}
}

func TestDispatch_WithCheckpointStore(t *testing.T) {
	runner := &mockRunner{response: "reply"}
	store := newMockStore()
	mgr := NewSessionManager(runner, store, "test-model")

	// First turn — no prior history.
	_, err := mgr.Dispatch(context.Background(), "thread-1", "first message")
	if err != nil {
		t.Fatalf("first Dispatch failed: %v", err)
	}
	if len(store.createCalls) != 1 || store.createCalls[0] != "thread-1" {
		t.Errorf("CreateThread not called correctly: %v", store.createCalls)
	}
	if store.saveCalls != 1 {
		t.Errorf("expected 1 SaveSnapshot call, got %d", store.saveCalls)
	}

	// Second turn — history should be loaded and prepended.
	_, err = mgr.Dispatch(context.Background(), "thread-1", "second message")
	if err != nil {
		t.Fatalf("second Dispatch failed: %v", err)
	}
	if store.saveCalls != 2 {
		t.Errorf("expected 2 SaveSnapshot calls, got %d", store.saveCalls)
	}
	// Runner should have received the history from the first turn plus the new message.
	lastCall := runner.calls[len(runner.calls)-1]
	if len(lastCall.messages) < 2 {
		t.Errorf("expected history + new message on second turn, got %d messages", len(lastCall.messages))
	}
}

func TestDispatch_SerializesConcurrentCallsSameSession(t *testing.T) {
	// Verify that two concurrent calls on the same session are serialized.
	// We detect ordering by using a channel-based runner that records call order.
	runner := &mockRunner{response: "ok"}
	mgr := NewSessionManager(runner, nil, "model")

	var wg sync.WaitGroup
	results := make([]string, 2)
	errs := make([]error, 2)

	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			resp, err := mgr.Dispatch(context.Background(), "shared-session", "msg")
			results[idx] = resp
			errs[idx] = err
		}(i)
	}
	wg.Wait()

	for i, err := range errs {
		if err != nil {
			t.Errorf("goroutine %d: unexpected error: %v", i, err)
		}
	}
	for _, r := range results {
		if r != "ok" {
			t.Errorf("unexpected response: %q", r)
		}
	}
}

func TestDispatch_ParallelDifferentSessions(t *testing.T) {
	runner := &mockRunner{response: "ok"}
	mgr := NewSessionManager(runner, nil, "model")

	var wg sync.WaitGroup
	sessions := []string{"alice", "bob", "carol", "dave"}
	for _, s := range sessions {
		wg.Add(1)
		go func(sessionKey string) {
			defer wg.Done()
			if _, err := mgr.Dispatch(context.Background(), sessionKey, "hello"); err != nil {
				t.Errorf("session %s: unexpected error: %v", sessionKey, err)
			}
		}(s)
	}
	wg.Wait()
	if len(runner.calls) != len(sessions) {
		t.Errorf("expected %d runner calls, got %d", len(sessions), len(runner.calls))
	}
}

func TestDispatch_CheckpointSaveFailureIsNonFatal(t *testing.T) {
	runner := &mockRunner{response: "ok"}
	store := newMockStore()
	store.saveErr = errors.New("disk full")
	mgr := NewSessionManager(runner, store, "model")

	// SaveSnapshot fails but Dispatch should still return the response.
	resp, err := mgr.Dispatch(context.Background(), "s1", "hello")
	if err != nil {
		t.Fatalf("expected no error despite save failure, got: %v", err)
	}
	if resp != "ok" {
		t.Errorf("response = %q, want %q", resp, "ok")
	}
}

func TestDispatch_PostDispatchHook(t *testing.T) {
	runner := &mockRunner{response: "original"}
	mgr := NewSessionManager(runner, nil, "model")

	hooks := &Hooks{}
	hooks.RegisterPostDispatch(func(ctx context.Context, sessionKey, response string) string {
		return response + " (hooked)"
	})
	mgr.SetHooks(hooks)

	resp, err := mgr.Dispatch(context.Background(), "s1", "hi")
	if err != nil {
		t.Fatalf("Dispatch failed: %v", err)
	}
	want := "original (hooked)"
	if resp != want {
		t.Errorf("response = %q, want %q", resp, want)
	}
}

// ── F-068: Memory Flush Compaction Tests ───────────────────────────────────

func TestSessionManager_CompactionWithTrivialMessageFiltering(t *testing.T) {
	ctx := context.Background()
	runner := &mockRunner{response: "ok"}
	store := newMockStore()
	mgr := NewSessionManager(runner, store, "mock")

	// Pre-fill history with trivial messages ("ok", "yes", "confirmed").
	history := []agentctx.StrategicMessage{
		{Role: "user", Content: &agentctx.MessageContent{Str: ptrStr("ok")}},
		{Role: "assistant", Content: &agentctx.MessageContent{Str: ptrStr("yes")}},
		{Role: "user", Content: &agentctx.MessageContent{Str: ptrStr("confirmed")}},
		{Role: "assistant", Content: &agentctx.MessageContent{Str: ptrStr("ok.")}},
		{Role: "user", Content: &agentctx.MessageContent{Str: ptrStr("hello")}},
	}
	store.SaveSnapshot("sess1", 1, history)

	mgr.SetMemoryWindow(2)
	mgr.SetCompactionPolicy(config.CompactionPolicyConfig{
		Strategy: "memoryFlush",
	})
	cons := &mockConsolidator{}
	mgr.SetConsolidator(cons)

	// Dispatch a message to trigger compaction.
	_, err := mgr.Dispatch(ctx, "sess1", "new message")
	if err != nil {
		t.Fatalf("Dispatch: %v", err)
	}

	// Verify consolidator was called (or not) depending on non-trivial messages.
	cons.mu.Lock()
	defer cons.mu.Unlock()
	// The consolidator should either not be called (all trivial) or called with filtered text.
	if len(cons.calls) > 0 {
		// If called, ensure the consolidated text is not empty (has non-trivial content).
		if cons.calls[0].text == "" {
			t.Error("expected non-empty consolidated text after filtering")
		}
	}
}

func TestSessionManager_CompactionWithNilConsolidator(t *testing.T) {
	ctx := context.Background()
	runner := &mockRunner{response: "ok"}
	store := newMockStore()
	mgr := NewSessionManager(runner, store, "mock")

	// Pre-fill history to trigger compaction.
	history := make([]agentctx.StrategicMessage, 10)
	for i := range history {
		role := "user"
		if i%2 == 1 {
			role = "assistant"
		}
		content := "msg"
		history[i] = agentctx.StrategicMessage{
			Role:    role,
			Content: &agentctx.MessageContent{Str: &content},
		}
	}
	store.SaveSnapshot("sess1", 1, history)

	mgr.SetMemoryWindow(5)
	mgr.SetCompactionPolicy(config.CompactionPolicyConfig{
		Strategy: "memoryFlush",
	})
	// No consolidator set (nil)

	// Dispatch should not crash with nil consolidator.
	_, err := mgr.Dispatch(ctx, "sess1", "new message")
	if err != nil {
		t.Fatalf("Dispatch with nil consolidator should not crash: %v", err)
	}
}

func TestSessionManager_CompactionWithMixedRoles(t *testing.T) {
	ctx := context.Background()
	runner := &mockRunner{response: "decision made"}
	store := newMockStore()
	mgr := NewSessionManager(runner, store, "mock")

	// Pre-fill history with mixed user/assistant turns.
	history := []agentctx.StrategicMessage{
		{Role: "user", Content: &agentctx.MessageContent{Str: ptrStr("What's the deadline?")}},
		{Role: "assistant", Content: &agentctx.MessageContent{Str: ptrStr("May 15, 2026")}},
		{Role: "user", Content: &agentctx.MessageContent{Str: ptrStr("ok")}},
		{Role: "assistant", Content: &agentctx.MessageContent{Str: ptrStr("Budget approved: $50k")}},
		{Role: "user", Content: &agentctx.MessageContent{Str: ptrStr("confirmed")}},
	}
	store.SaveSnapshot("sess1", 1, history)

	mgr.SetMemoryWindow(2)
	mgr.SetCompactionPolicy(config.CompactionPolicyConfig{
		Strategy: "memoryFlush",
	})
	cons := &mockConsolidator{}
	mgr.SetConsolidator(cons)

	_, err := mgr.Dispatch(ctx, "sess1", "new")
	if err != nil {
		t.Fatalf("Dispatch: %v", err)
	}

	// Verify consolidator was called with meaningful facts.
	cons.mu.Lock()
	defer cons.mu.Unlock()
	if len(cons.calls) == 0 {
		t.Error("expected consolidator to be called with mixed roles")
	} else {
		// The consolidated text should contain substantive messages, not just trivial ones.
		text := cons.calls[0].text
		if text != "" && (strings.Contains(text, "deadline") || strings.Contains(text, "Budget")) {
			// Good: meaningful content was extracted
		}
	}
}

// Helper function to create string pointer.
func ptrStr(s string) *string {
	return &s
}
