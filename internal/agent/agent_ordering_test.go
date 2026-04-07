package agent

import (
	"context"
	"fmt"
	"sync"
	"testing"
	"time"

	agentctx "github.com/allthingscode/gobot/internal/context"
)

// delayedRunner simulates API latency to amplify race conditions.
// It is a separate type from mockRunner to avoid name collision.
type delayedRunner struct {
	delay    time.Duration
	response string
	mu       sync.Mutex
	calls    int
}

func (r *delayedRunner) RunText(_ context.Context, _, _, _ string) (string, error) {

	return r.response, nil
}

func (r *delayedRunner) Run(_ context.Context, _ string, messages []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error) {
	if r.delay > 0 {
		time.Sleep(r.delay)
	}
	r.mu.Lock()
	r.calls++
	r.mu.Unlock()
	updated := append(messages, agentctx.StrategicMessage{Role: agentctx.RoleAssistant}) //nolint:gocritic // intentional: return a new slice without mutating input
	return r.response, updated, nil
}

// TestSessionManager_OrderedIterations verifies that concurrent dispatches to
// the same session produce monotonically increasing iteration numbers with no
// gaps or duplicates — proof that per-session serialization is correct.
func TestSessionManager_OrderedIterations(t *testing.T) {
	t.Parallel()
	const n = 20
	store := newMockStore()
	runner := &delayedRunner{delay: 2 * time.Millisecond, response: "ok"}
	mgr := NewSessionManager(runner, store, "model")

	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := mgr.Dispatch(context.Background(), "ordered-session", "msg"); err != nil {
				t.Errorf("Dispatch: %v", err)
			}
		}()
	}
	wg.Wait()

	store.mu.Lock()
	snap := store.snapshots["ordered-session"]
	saveCalls := store.saveCalls
	store.mu.Unlock()

	if saveCalls != n {
		t.Errorf("expected %d SaveSnapshot calls, got %d", n, saveCalls)
	}
	if snap == nil {
		t.Fatal("no snapshot saved for ordered-session")
	}
	// If serialization is correct, each Dispatch increments iteration by exactly 1,
	// so the final value must equal n.
	if snap.Iteration != n {
		t.Errorf("final iteration = %d, want %d (gap or duplicate iteration detected)", snap.Iteration, n)
	}
}

// TestSessionManager_ParallelSessionsNoInterference verifies that dispatches
// to different sessions proceed independently and each session accumulates its
// own iteration counter without cross-session contamination.
func TestSessionManager_ParallelSessionsNoInterference(t *testing.T) {
	t.Parallel()
	const sessions = 10
	const msgsPerSession = 5
	store := newMockStore()
	runner := &delayedRunner{delay: 2 * time.Millisecond, response: "ok"}
	mgr := NewSessionManager(runner, store, "model")

	var wg sync.WaitGroup
	for s := 0; s < sessions; s++ {
		for m := 0; m < msgsPerSession; m++ {
			wg.Add(1)
			go func(sessionIdx int) {
				defer wg.Done()
				key := fmt.Sprintf("sess-%d", sessionIdx)
				if _, err := mgr.Dispatch(context.Background(), key, "msg"); err != nil {
					t.Errorf("Dispatch: %v", err)
				}
			}(s)
		}
	}
	wg.Wait()

	store.mu.Lock()
	defer store.mu.Unlock()
	for s := 0; s < sessions; s++ {
		key := fmt.Sprintf("sess-%d", s)
		snap := store.snapshots[key]
		if snap == nil {
			t.Errorf("no snapshot for %s", key)
			continue
		}
		if snap.Iteration != msgsPerSession {
			t.Errorf("%s: final iteration = %d, want %d", key, snap.Iteration, msgsPerSession)
		}
	}
}
