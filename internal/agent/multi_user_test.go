//nolint:testpackage // requires unexported mock types for testing
package agent

import (
	"context"
	"fmt"
	"sync"
	"testing"
	"time"

	agentctx "github.com/allthingscode/gobot/internal/context"
)

// perUserCheckpointStore is a thread-safe in-memory CheckpointStore keyed by threadID.
// It tracks which threadIDs were accessed to verify per-user isolation.
type perUserCheckpointStore struct {
	mu       sync.Mutex
	threads  map[string]*agentctx.ThreadSnapshot
	recorded []string // threadIDs touched on this store
}

func (s *perUserCheckpointStore) LoadLatest(_ context.Context, threadID string) (*agentctx.ThreadSnapshot, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.recorded = append(s.recorded, threadID)
	snap, ok := s.threads[threadID]
	if !ok {
		return nil, nil
	}
	return snap, nil
}

func (s *perUserCheckpointStore) SaveSnapshot(_ context.Context, threadID string, iteration int, messages []agentctx.StrategicMessage) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.recorded = append(s.recorded, threadID)
	s.threads[threadID] = &agentctx.ThreadSnapshot{
		Iteration: iteration,
		Messages:  messages,
	}
	return true, nil
}

func (s *perUserCheckpointStore) CreateThread(_ context.Context, threadID, _ string, _ map[string]any) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.recorded = append(s.recorded, threadID)
	return nil
}

func (s *perUserCheckpointStore) UpdateSessionTokens(_ context.Context, _ string, _ int, _ *time.Time) error {
	return nil
}

func (s *perUserCheckpointStore) GetSessionTokens(_ context.Context, _ string) (int, *time.Time, error) {
	return 0, nil, nil
}

// TestMultiUserCheckpointIsolation verifies that when a CheckpointStoreProvider is
// configured, each userID receives its own store and thread data does not cross users.
//
//nolint:cyclop // test complexity justified by multi-scenario coverage
func TestMultiUserCheckpointIsolation(t *testing.T) {
	t.Parallel()

	storeA := &perUserCheckpointStore{threads: make(map[string]*agentctx.ThreadSnapshot)}
	storeB := &perUserCheckpointStore{threads: make(map[string]*agentctx.ThreadSnapshot)}

	storeMap := map[string]*perUserCheckpointStore{
		"alice": storeA,
		"bob":   storeB,
	}

	provider := func(userID string) (CheckpointStore, error) {
		s, ok := storeMap[userID]
		if !ok {
			return nil, fmt.Errorf("unknown userID: %s", userID)
		}
		return s, nil
	}

	runner := &mockRunner{response: "ok"}
	mgr := NewSessionManager(runner, nil, "test-model")
	mgr.SetCheckpointStoreProvider(provider)

	ctx := context.Background()

	replyA, err := mgr.Dispatch(ctx, "session-alice", "alice", "hello from alice")
	if err != nil {
		t.Fatalf("alice dispatch: %v", err)
	}
	if replyA == "" {
		t.Fatal("alice: empty reply")
	}

	replyB, err := mgr.Dispatch(ctx, "session-bob", "bob", "hello from bob")
	if err != nil {
		t.Fatalf("bob dispatch: %v", err)
	}
	if replyB == "" {
		t.Fatal("bob: empty reply")
	}

	// Alice's store must only contain Alice's session.
	storeA.mu.Lock()
	for _, threadID := range storeA.recorded {
		if threadID != "session-alice" {
			t.Errorf("alice store: unexpected threadID %q (expected session-alice only)", threadID)
		}
	}
	_, aliceHasBob := storeA.threads["session-bob"]
	storeA.mu.Unlock()
	if aliceHasBob {
		t.Error("alice store unexpectedly contains bob's session data")
	}

	// Bob's store must only contain Bob's session.
	storeB.mu.Lock()
	for _, threadID := range storeB.recorded {
		if threadID != "session-bob" {
			t.Errorf("bob store: unexpected threadID %q (expected session-bob only)", threadID)
		}
	}
	_, bobHasAlice := storeB.threads["session-alice"]
	storeB.mu.Unlock()
	if bobHasAlice {
		t.Error("bob store unexpectedly contains alice's session data")
	}
}

// TestMultiUserProviderFallback verifies that when the provider returns an error,
// the SessionManager falls back to the shared store gracefully.
func TestMultiUserProviderFallback(t *testing.T) {
	t.Parallel()

	sharedStore := &perUserCheckpointStore{threads: make(map[string]*agentctx.ThreadSnapshot)}

	provider := func(_ string) (CheckpointStore, error) {
		return nil, fmt.Errorf("provider unavailable")
	}

	runner := &mockRunner{response: "fallback-ok"}
	mgr := NewSessionManager(runner, sharedStore, "test-model")
	mgr.SetCheckpointStoreProvider(provider)

	ctx := context.Background()
	reply, err := mgr.Dispatch(ctx, "sess-fallback", "unknown-user", "ping")
	if err != nil {
		t.Fatalf("dispatch with fallback: %v", err)
	}
	if reply == "" {
		t.Fatal("expected non-empty reply on fallback path")
	}

	sharedStore.mu.Lock()
	accessed := len(sharedStore.recorded) > 0
	sharedStore.mu.Unlock()
	if !accessed {
		t.Error("expected shared store to be used as fallback when provider fails")
	}
}

// TestSingleUserNoProviderRegression verifies the classic single-user path
// (no provider configured) still works correctly after F-105 changes.
func TestSingleUserNoProviderRegression(t *testing.T) {
	t.Parallel()

	store := &perUserCheckpointStore{threads: make(map[string]*agentctx.ThreadSnapshot)}
	runner := &mockRunner{response: "classic-ok"}
	mgr := NewSessionManager(runner, store, "test-model")
	// No provider set.

	ctx := context.Background()
	reply, err := mgr.Dispatch(ctx, "sess-single", "user-1", "hello")
	if err != nil {
		t.Fatalf("single-user dispatch: %v", err)
	}
	if reply == "" {
		t.Fatal("expected non-empty reply")
	}

	store.mu.Lock()
	accessed := len(store.recorded) > 0
	store.mu.Unlock()
	if !accessed {
		t.Error("expected store to be accessed in single-user mode")
	}
}
