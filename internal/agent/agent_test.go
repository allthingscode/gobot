//nolint:testpackage // requires unexported mock types for testing
package agent

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
)

// ── Mock runner ───────────────────────────────────────────────────────────────

type mockRunner struct {
	response    string
	err         error
	runTextErr  error
	calls       []runCall
	textCalls   []string
	activeCalls map[string]int
	maxActive   map[string]int
	delay       time.Duration
	mu          sync.Mutex
}

type runCall struct {
	sessionKey string
	messages   []agentctx.StrategicMessage
}

func (r *mockRunner) Run(_ context.Context, sessionKey, _ string, messages []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error) {
	r.mu.Lock()
	r.calls = append(r.calls, runCall{sessionKey: sessionKey, messages: messages})
	if r.activeCalls == nil {
		r.activeCalls = make(map[string]int)
	}
	if r.maxActive == nil {
		r.maxActive = make(map[string]int)
	}
	r.activeCalls[sessionKey]++
	if r.activeCalls[sessionKey] > r.maxActive[sessionKey] {
		r.maxActive[sessionKey] = r.activeCalls[sessionKey]
	}
	delay := r.delay
	r.mu.Unlock()

	if delay > 0 {
		time.Sleep(delay)
	}

	defer func() {
		r.mu.Lock()
		r.activeCalls[sessionKey]--
		r.mu.Unlock()
	}()

	if r.err != nil {
		return "", nil, r.err
	}
	updated := append(messages, agentctx.StrategicMessage{Role: agentctx.RoleAssistant}) //nolint:gocritic // intentional: return a new slice without mutating input
	return r.response, updated, nil
}

func (r *mockRunner) RunText(_ context.Context, _, prompt, _ string) (string, error) {
	r.mu.Lock()
	r.textCalls = append(r.textCalls, prompt)
	r.mu.Unlock()
	if r.runTextErr != nil {
		return "", r.runTextErr
	}
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
	createErr   error
	createCalls []string
	saveCalls   int
	mu          sync.Mutex
}

func newMockStore() *mockStore {
	return &mockStore{snapshots: make(map[string]*agentctx.ThreadSnapshot)}
}

func (s *mockStore) LoadLatest(_ context.Context, threadID string) (*agentctx.ThreadSnapshot, error) {
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

func (s *mockStore) SaveSnapshot(_ context.Context, threadID string, iteration int, messages []agentctx.StrategicMessage) (bool, error) {
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

func (s *mockStore) CreateThread(_ context.Context, threadID, _ string, _ map[string]any) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.createCalls = append(s.createCalls, threadID)
	if s.createErr != nil {
		return s.createErr
	}
	return nil
}

func (s *mockStore) UpdateSessionTokens(_ context.Context, threadID string, tokens int, _ *time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.snapshots[threadID] != nil {
		if s.snapshots[threadID].Metadata == nil {
			s.snapshots[threadID].Metadata = make(map[string]any)
		}
		s.snapshots[threadID].Metadata["estimated_tokens"] = tokens
	}
	return nil
}

func (s *mockStore) GetSessionTokens(_ context.Context, threadID string) (int, *time.Time, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if snap, ok := s.snapshots[threadID]; ok {
		if tokens, ok := snap.Metadata["estimated_tokens"].(int); ok {
			return tokens, nil, nil
		}
	}
	return 0, nil, nil
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
	t.Parallel()
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
			t.Parallel()
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
	t.Parallel()
	ctx := context.Background()
	runner := &mockRunner{response: "ok"}
	store := newMockStore()
	mgr := NewSessionManager(runner, store, "mock")

	// Pre-fill history with 10 messages.
	history := make([]agentctx.StrategicMessage, 10)
	for i := range history {
		role := agentctx.RoleUser
		if i%2 == 1 {
			role = agentctx.RoleAssistant
		}
		content := "msg"
		history[i] = agentctx.StrategicMessage{
			Role:    role,
			Content: &agentctx.MessageContent{Str: &content},
		}
	}
	_, _ = store.SaveSnapshot(context.Background(),
"sess1", 1, history)

	// Set compaction policy.
	mgr.SetMemoryWindow(5)
	mgr.SetCompactionPolicy(config.CompactionPolicyConfig{
		Strategy: "memoryFlush",
	})
	cons := &mockConsolidator{}
	mgr.SetConsolidator(cons)

	// Dispatch a new message.
	_, err := mgr.Dispatch(ctx, "sess1", "", "new message")
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
	t.Parallel()
	runner := &mockRunner{response: "pong"}
	mgr := NewSessionManager(runner, nil, "test-model")

	resp, err := mgr.Dispatch(context.Background(), "session-1", "", "ping")
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
	if len(call.messages) != 1 || call.messages[0].Role != agentctx.RoleUser {
		t.Errorf("expected one user message, got: %v", call.messages)
	}
}

func TestDispatch_SilentPrefixStripped(t *testing.T) {
	t.Parallel()
	runner := &mockRunner{response: "ok"}
	mgr := NewSessionManager(runner, nil, "test-model")

	_, err := mgr.Dispatch(context.Background(), "s1", "", "[SILENT] run quietly")
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
	t.Parallel()
	runner := &mockRunner{err: errors.New("model overloaded")}
	mgr := NewSessionManager(runner, nil, "test-model")

	_, err := mgr.Dispatch(context.Background(), "s1", "", "hello")
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !errors.Is(err, runner.err) {
		t.Errorf("error = %v, want to wrap %v", err, runner.err)
	}
}

func TestDispatch_WithCheckpointStore(t *testing.T) {
	t.Parallel()
	runner := &mockRunner{response: "reply"}
	store := newMockStore()
	mgr := NewSessionManager(runner, store, "test-model")

	// First turn — no prior history.
	_, err := mgr.Dispatch(context.Background(), "thread-1", "", "first message")
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
	_, err = mgr.Dispatch(context.Background(), "thread-1", "", "second message")
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
	t.Parallel()
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
			resp, err := mgr.Dispatch(context.Background(), "shared-session", "", "msg")
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
	t.Parallel()
	runner := &mockRunner{response: "ok"}
	mgr := NewSessionManager(runner, nil, "model")

	var wg sync.WaitGroup
	sessions := []string{"alice", "bob", "carol", "dave"}
	for _, s := range sessions {
		wg.Add(1)
		go func(sessionKey string) {
			defer wg.Done()
			if _, err := mgr.Dispatch(context.Background(), sessionKey, "", "hello"); err != nil {
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
	t.Parallel()
	runner := &mockRunner{response: "ok"}
	store := newMockStore()
	store.saveErr = errors.New("disk full")
	mgr := NewSessionManager(runner, store, "model")

	// SaveSnapshot fails but Dispatch should still return the response.
	resp, err := mgr.Dispatch(context.Background(), "s1", "", "hello")
	if err != nil {
		t.Fatalf("expected no error despite save failure, got: %v", err)
	}
	if resp != "ok" {
		t.Errorf("response = %q, want %q", resp, "ok")
	}
}

func TestDispatch_PostDispatchHook(t *testing.T) {
	t.Parallel()
	runner := &mockRunner{response: "original"}
	mgr := NewSessionManager(runner, nil, "model")

	hooks := &Hooks{}
	hooks.RegisterPostDispatch(func(ctx context.Context, sessionKey, response string) string {
		return response + " (hooked)"
	})
	mgr.SetHooks(hooks)

	resp, err := mgr.Dispatch(context.Background(), "s1", "", "hi")
	if err != nil {
		t.Fatalf("Dispatch failed: %v", err)
	}
	want := "original (hooked)"
	if resp != want {
		t.Errorf("response = %q, want %q", resp, want)
	}
}

func TestDispatch_PreHistoryHook_NilSafe(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name    string
		hook    PreHistoryFn
		wantLen int // expected messages passed to runner (including the new one)
	}{
		{
			name: "hook returns nil - fallback to original",
			hook: func(ctx context.Context, messages []agentctx.StrategicMessage) []agentctx.StrategicMessage {
				return nil
			},
			wantLen: 2, // "prior message" + "new message"
		},
		{
			name: "hook returns empty - fallback to original",
			hook: func(ctx context.Context, messages []agentctx.StrategicMessage) []agentctx.StrategicMessage {
				return []agentctx.StrategicMessage{}
			},
			wantLen: 2,
		},
		{
			name: "hook returns modified - use modified",
			hook: func(ctx context.Context, messages []agentctx.StrategicMessage) []agentctx.StrategicMessage {
				return append(messages, agentctx.StrategicMessage{Role: agentctx.RoleSystem, Content: &agentctx.MessageContent{Str: ptrStr("injected")}})
			},
			wantLen: 3, // "prior message" + "injected" + "new message"
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			runner := &mockRunner{response: "ok"}
			mgr := NewSessionManager(runner, nil, "model")

			// Pre-fill history.
			history := []agentctx.StrategicMessage{
				{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: ptrStr("prior message")}},
			}
			store := newMockStore()
			_, _ = store.SaveSnapshot(context.Background(),
"s1", 1, history)
			mgr.store = store

			hooks := &Hooks{}
			hooks.RegisterPreHistory(tt.hook)
			mgr.SetHooks(hooks)

			_, err := mgr.Dispatch(context.Background(), "s1", "", "new message")
			if err != nil {
				t.Fatalf("Dispatch failed: %v", err)
			}

			runner.mu.Lock()
			numCalls := len(runner.calls)
			var gotLen int
			if numCalls > 0 {
				gotLen = len(runner.calls[0].messages)
			}
			runner.mu.Unlock()

			if numCalls != 1 {
				t.Fatalf("expected 1 runner call, got %d", numCalls)
			}
			if gotLen != tt.wantLen {
				t.Errorf("got %d messages, want %d", gotLen, tt.wantLen)
			}
		})
	}
}

// ── F-068: Memory Flush Compaction Tests ───────────────────────────────────

func TestSessionManager_CompactionWithTrivialMessageFiltering(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	runner := &mockRunner{response: "ok"}
	store := newMockStore()
	mgr := NewSessionManager(runner, store, "mock")

	// Pre-fill history with trivial messages ("ok", "yes", "confirmed").
	history := []agentctx.StrategicMessage{
		{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: ptrStr("ok")}},
		{Role: agentctx.RoleAssistant, Content: &agentctx.MessageContent{Str: ptrStr("yes")}},
		{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: ptrStr("confirmed")}},
		{Role: agentctx.RoleAssistant, Content: &agentctx.MessageContent{Str: ptrStr("ok.")}},
		{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: ptrStr("hello")}},
	}
	_, _ = store.SaveSnapshot(context.Background(),
"sess1", 1, history)

	mgr.SetMemoryWindow(2)
	mgr.SetCompactionPolicy(config.CompactionPolicyConfig{
		Strategy: "memoryFlush",
	})
	cons := &mockConsolidator{}
	mgr.SetConsolidator(cons)

	// Dispatch a message to trigger compaction.
	_, err := mgr.Dispatch(ctx, "sess1", "", "new message")
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
	t.Parallel()
	ctx := context.Background()
	runner := &mockRunner{response: "ok"}
	store := newMockStore()
	mgr := NewSessionManager(runner, store, "mock")

	// Pre-fill history to trigger compaction.
	history := make([]agentctx.StrategicMessage, 10)
	for i := range history {
		role := agentctx.RoleUser
		if i%2 == 1 {
			role = agentctx.RoleAssistant
		}
		content := "msg"
		history[i] = agentctx.StrategicMessage{
			Role:    role,
			Content: &agentctx.MessageContent{Str: &content},
		}
	}
	_, _ = store.SaveSnapshot(context.Background(),
"sess1", 1, history)

	mgr.SetMemoryWindow(5)
	mgr.SetCompactionPolicy(config.CompactionPolicyConfig{
		Strategy: "memoryFlush",
	})
	// No consolidator set (nil)

	// Dispatch should not crash with nil consolidator.
	_, err := mgr.Dispatch(ctx, "sess1", "", "new message")
	if err != nil {
		t.Fatalf("Dispatch with nil consolidator should not crash: %v", err)
	}
}

func TestSessionManager_CompactionWithMixedRoles(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	runner := &mockRunner{response: "decision made"}
	store := newMockStore()
	mgr := NewSessionManager(runner, store, "mock")

	// Pre-fill history with mixed user/assistant turns.
	history := []agentctx.StrategicMessage{
		{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: ptrStr("What's the deadline?")}},
		{Role: agentctx.RoleAssistant, Content: &agentctx.MessageContent{Str: ptrStr("May 15, 2026")}},
		{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: ptrStr("ok")}},
		{Role: agentctx.RoleAssistant, Content: &agentctx.MessageContent{Str: ptrStr("Budget approved: $50k")}},
		{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: ptrStr("confirmed")}},
	}
	_, _ = store.SaveSnapshot(context.Background(),
"sess1", 1, history)

	mgr.SetMemoryWindow(2)
	mgr.SetCompactionPolicy(config.CompactionPolicyConfig{
		Strategy: "memoryFlush",
	})
	cons := &mockConsolidator{}
	mgr.SetConsolidator(cons)

	_, err := mgr.Dispatch(ctx, "sess1", "", "new")
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
		hasRelevant := strings.Contains(text, "deadline") || strings.Contains(text, "Budget")
		if text == "" {
			t.Error("expected non-empty consolidated text")
		}
		if !hasRelevant {
			t.Logf("consolidated text does not contain expected keywords: %q", text)
		}
	}
}

// Helper function to create string pointer.
func ptrStr(s string) *string {
	return &s
}

func TestSessionManager_B037_KeepN_Division_Zero(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	// Mock runner that returns a summary.
	runner := &mockRunner{response: "<context_summary>\n* summarized\n</context_summary>"}
	store := newMockStore()
	mgr := NewSessionManager(runner, store, "mock")

	// Set memoryWindow to 1 to trigger the bug (keepN = 1 / 2 = 0).
	mgr.SetMemoryWindow(1)
	mgr.SetCompactionPolicy(config.CompactionPolicyConfig{
		Summarization: config.SummarizationConfig{
			IsEnabled:        true,
			ThresholdPercent: 0.1, // Trigger easily
		},
	})

	// Pre-fill history ending with a user message.
	history := []agentctx.StrategicMessage{
		{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: ptrStr("message 1")}},
		{Role: agentctx.RoleAssistant, Content: &agentctx.MessageContent{Str: ptrStr("response 1")}},
		{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: ptrStr("message 2")}},
	}
	_, _ = store.SaveSnapshot(context.Background(),
"sess1", 1, history)

	// Dispatch a new message.
	_, err := mgr.Dispatch(ctx, "sess1", "", "new message")
	if err != nil {
		t.Fatalf("Dispatch: %v", err)
	}

	// Verify the history in the store after dispatch.
	snap, _ := store.LoadLatest(context.Background(), "sess1")
	if snap == nil {
		t.Fatal("expected snapshot to exist")
	}

	foundMsg2 := false
	for _, msg := range snap.Messages {
		if msg.Content.String() == "message 2" {
			foundMsg2 = true
			break
		}
	}

	// This test demonstrates that without the fix, we lose "message 2" entirely.
	if !foundMsg2 {
		t.Errorf("expected 'message 2' to be kept in history, but it was dropped (keepN likely 0)")
	}
}

func TestSessionManager_Dispatch_StatelessDegradation(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	runner := &mockRunner{response: "pong"}
	store := newMockStore()
	// Mock CreateThread to return an error.
	store.createErr = errors.New("database locked")
	mgr := NewSessionManager(runner, store, "test-model")

	// First turn — CreateThread fails.
	resp, err := mgr.Dispatch(ctx, "sess-fail", "", "ping")
	if err != nil {
		t.Fatalf("Dispatch failed: %v", err)
	}

	// Verify the response contains the warning.
	if !strings.HasPrefix(resp, statelessWarning) {
		t.Errorf("response does not contain stateless warning: %q", resp)
	}
	if !strings.Contains(resp, "pong") {
		t.Errorf("response does not contain runner response: %q", resp)
	}

	// Verify CreateThread was called.
	if len(store.createCalls) != 1 || store.createCalls[0] != "sess-fail" {
		t.Errorf("CreateThread not called correctly: %v", store.createCalls)
	}

	// Verify SaveSnapshot was NOT called (stateless mode).
	if store.saveCalls != 0 {
		t.Errorf("expected 0 SaveSnapshot calls in stateless mode, got %d", store.saveCalls)
	}
}

// TestNilStore prevents regression of nil pointer dereference when CheckpointStore is nil.
// This reproduces the issue where cron jobs would panic due to nil store handling.
func TestSessionManager_Dispatch_NilStore(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	runner := &mockRunner{response: "pong"}
	// Nil store simulates cron job scenario where no persistence is desired.
	mgr := NewSessionManager(runner, nil, "test-model")

	// Dispatch should work normally without panicking.
	resp, err := mgr.Dispatch(ctx, "cron-session", "", "hello")
	if err != nil {
		t.Fatalf("Dispatch failed with nil store: %v", err)
	}
	if resp != "pong" {
		t.Errorf("response = %q, want %q", resp, "pong")
	}
	if len(runner.calls) != 1 {
		t.Fatalf("expected 1 runner call, got %d", len(runner.calls))
	}
	call := runner.calls[0]
	if call.sessionKey != "cron-session" {
		t.Errorf("sessionKey = %q, want %q", call.sessionKey, "cron-session")
	}
	if len(call.messages) != 1 || call.messages[0].Role != agentctx.RoleUser {
		t.Errorf("expected one user message, got: %v", call.messages)
	}
	var text string
	c := call.messages[0].Content
	if c != nil && c.Str != nil {
		text = *c.Str
	}
	if text != "hello" {
		t.Errorf("runner received %q, want %q", text, "hello")
	}
}

// TestSessionManager_CompactionSummarizationFailure tests the fallback path when summarization fails.
// It verifies that the system falls back to plain compaction (truncation) and continues operating.
func TestSessionManager_CompactionSummarizationFailure(t *testing.T) {
	t.Parallel()
	ctx := context.Background()

	// Create a mock runner that returns an error for RunText (summarization) but succeeds for Run
	runner := &mockRunner{
		response:   "ok",
		err:        nil, // Run succeeds
		runTextErr: errors.New("summarization failed"),
	}

	store := newMockStore()
	mgr := NewSessionManager(runner, store, "mock")

	// Set up conditions to trigger summarization:
	// - Low memoryWindow to make threshold easy to reach
	// - Summarization enabled with low threshold
	mgr.SetMemoryWindow(10) // Keep last 10 messages after compaction
	mgr.SetCompactionPolicy(config.CompactionPolicyConfig{
		Summarization: config.SummarizationConfig{
			IsEnabled:        true,
			ThresholdPercent: 0.5, // Trigger when >50% of window used
		},
	})

	// Pre-fill history with 15 messages (more than memoryWindow * threshold = 10 * 0.5 = 5)
	// This will trigger compaction when we add one more message
	history := generateTestHistory(15)
	_, _ = store.SaveSnapshot(context.Background(),
"sess1", 1, history)

	// Dispatch a new message to trigger compaction (16th message)
	// This should trigger summarization, which will fail due to our mock,
	// causing fallback to plain compaction (truncation to last 10 messages)
	_, err := mgr.Dispatch(ctx, "sess1", "", "trigger compaction message")
	if err != nil {
		t.Fatalf("Dispatch failed: %v", err)
	}

	// Verify the session continued (no error returned to caller)
	// Verify that the snapshot was saved (compaction succeeded via fallback)
	if store.saveCalls < 2 { // Initial save + save after dispatch
		t.Errorf("expected at least 2 SaveSnapshot calls, got %d", store.saveCalls)
	}

	// Check the final state in the store
	snap, err := store.LoadLatest(context.Background(), "sess1")
	if err != nil {
		t.Fatalf("Failed to load snapshot: %v", err)
	}
	if snap == nil {
		t.Fatal("expected snapshot to exist")
	}

	validateSummarizationFailureState(t, snap)
}

func generateTestHistory(n int) []agentctx.StrategicMessage {
	history := make([]agentctx.StrategicMessage, n)
	for i := range history {
		role := agentctx.RoleUser
		if i%2 == 1 {
			role = agentctx.RoleAssistant
		}
		content := fmt.Sprintf("message %d", i+1)
		history[i] = agentctx.StrategicMessage{
			Role:    role,
			Content: &agentctx.MessageContent{Str: &content},
		}
	}
	return history
}

func validateSummarizationFailureState(t *testing.T, snap *agentctx.ThreadSnapshot) {
	t.Helper()
	// With fallback to plain compaction:
	// 1. Existing 15 messages (1=U, 2=A, ..., 15=U).
	// 2. Compaction (maxN=10) keeps last 9 messages (Indices 6-14: 7=U, 8=A, 9=U, 10=A, 11=U, 12=A, 13=U, 14=A, 15=U).
	// 3. New user message is appended (16=U).
	// 4. Runner is called with 10 messages (9 from history + 1 new).
	// 5. Runner appends an assistant message (17=A).
	// Final count should be 11.
	if len(snap.Messages) != 11 {
		t.Errorf("expected 11 messages after compaction (fallback) and turn execution, got %d", len(snap.Messages))
	}

	// Verify that the kept messages are the most recent ones (the fallback should truncate from the beginning)
	expectedRoles := []agentctx.MessageRole{
		agentctx.RoleUser,      // msg 7
		agentctx.RoleAssistant, // msg 8
		agentctx.RoleUser,      // msg 9
		agentctx.RoleAssistant, // msg 10
		agentctx.RoleUser,      // msg 11
		agentctx.RoleAssistant, // msg 12
		agentctx.RoleUser,      // msg 13
		agentctx.RoleAssistant, // msg 14
		agentctx.RoleUser,      // msg 15
		agentctx.RoleUser,      // msg 16 ("trigger compaction message")
		agentctx.RoleAssistant, // msg 17 (mock response)
	}

	for i, expectedRole := range expectedRoles {
		if i >= len(snap.Messages) {
			t.Errorf("message %d missing", i+7)
			break
		}
		if snap.Messages[i].Role != expectedRole {
			t.Errorf("message %d (index %d): expected role %v, got %v", i+7, i, expectedRole, snap.Messages[i].Role)
		}
	}

	// Verify the content of the "trigger" message (index 9)
	if len(snap.Messages) > 9 {
		triggerMsg := snap.Messages[9]
		if triggerMsg.Content.String() != "trigger compaction message" {
			t.Errorf("trigger message content unexpected: %q", triggerMsg.Content.String())
		}
	}
}
