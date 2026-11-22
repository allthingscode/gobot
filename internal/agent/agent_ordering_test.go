//nolint:testpackage // requires unexported mock types for testing
package agent

import (
	"context"
	"fmt"
	"sync"
	"testing"
	"testing/synctest"

	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/stretchr/testify/assert"
)

// gatedRunner holds dispatches at observable entry until the test releases them.
// It is a separate type from mockRunner to avoid name collision.
type gatedRunner struct {
	entered  chan<- struct{}
	release  <-chan struct{}
	response string
	mu       sync.Mutex
	calls    int
}

func (r *gatedRunner) RunText(_ context.Context, _, _, _ string) (string, error) {
	return r.response, nil
}

func (r *gatedRunner) Run(_ context.Context, _, _ string, messages []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error) {
	r.entered <- struct{}{}
	<-r.release
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
	synctest.Test(t, checkOrderedIterations)
}

// TestSessionManager_ParallelSessionsNoInterference verifies that dispatches
// to different sessions proceed independently and each session accumulates its
// own iteration counter without cross-session contamination.
func TestSessionManager_ParallelSessionsNoInterference(t *testing.T) {
	t.Parallel()
	synctest.Test(t, checkParallelIterations)
}

func checkOrderedIterations(t *testing.T) {
	t.Helper()
	const n = 20
	store := newMockStore()
	entered := make(chan struct{}, 50)
	release := make(chan struct{})
	var once sync.Once
	unblock := func() { once.Do(func() { close(release) }) }
	defer unblock()
	runner := &gatedRunner{entered: entered, release: release, response: "ok"}
	mgr := NewSessionManager(runner, store, "model")

	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := mgr.Dispatch(context.Background(), "ordered-session", "", "msg"); err != nil {
				t.Errorf("Dispatch: %v", err)
			}
		}()
	}
	<-entered
	synctest.Wait()
	unblock()
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
	for i, iteration := range store.iterations["ordered-session"] {
		if iteration != i+1 {
			t.Errorf("iteration[%d] = %d, want %d", i, iteration, i+1)
		}
	}
	if snap.Iteration != n {
		t.Errorf("final iteration = %d, want %d (gap or duplicate iteration detected)", snap.Iteration, n)
	}
}

func checkParallelIterations(t *testing.T) {
	t.Helper()
	const sessions = 10
	const msgsPerSession = 5
	store := newMockStore()
	entered := make(chan struct{}, 50)
	release := make(chan struct{})
	var once sync.Once
	unblock := func() { once.Do(func() { close(release) }) }
	defer unblock()
	runner := &gatedRunner{entered: entered, release: release, response: "ok"}
	mgr := NewSessionManager(runner, store, "model")

	var wg sync.WaitGroup
	for s := 0; s < sessions; s++ {
		for m := 0; m < msgsPerSession; m++ {
			wg.Add(1)
			go func(sessionIdx int) {
				defer wg.Done()
				key := fmt.Sprintf("sess-%d", sessionIdx)
				if _, err := mgr.Dispatch(context.Background(), key, "", "msg"); err != nil {
					t.Errorf("Dispatch: %v", err)
				}
			}(s)
		}
	}
	for i := 0; i < sessions; i++ {
		<-entered
	}
	synctest.Wait()
	unblock()
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
		for i, iteration := range store.iterations[key] {
			assert.Equal(t, i+1, iteration, "%s iteration[%d]", key, i)
		}
		if snap.Iteration != msgsPerSession {
			t.Errorf("%s: final iteration = %d, want %d", key, snap.Iteration, msgsPerSession)
		}
	}
}
