//nolint:testpackage // requires unexported mock types for testing
package agent

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"testing"
	"testing/synctest"
)

// TestDispatch_Concurrent_SameSession verifies that 10 concurrent calls
// with the same session key are correctly serialized (no overlaps).
func TestDispatch_Concurrent_SameSession(t *testing.T) {
	t.Parallel()
	synctest.Test(t, func(t *testing.T) {
		entered := make(chan string, 10)
		release := make(chan struct{})
		var once sync.Once
		unblock := func() { once.Do(func() { close(release) }) }
		defer unblock()
		runner := &mockRunner{response: "ok", entered: entered, release: release}
		mgr := NewSessionManager(runner, nil, "model")

		const n = 10
		var wg sync.WaitGroup
		errs := make([]error, n)
		var mu sync.Mutex

		launch := func(idx int) {
			wg.Add(1)
			go func() {
				defer wg.Done()
				_, err := mgr.Dispatch(context.Background(), t.Name(), "", "msg")
				mu.Lock()
				errs[idx] = err
				mu.Unlock()
			}()
		}
		launch(0)
		<-entered // Establish the holder before launching its contenders.
		for i := 1; i < n; i++ {
			launch(i)
		}
		synctest.Wait()
		if got := GetLockMetrics()[t.Name()].WaitCount; got != n-1 {
			t.Errorf("waiters = %d, want %d", got, n-1)
		}
		if len(entered) != 0 {
			t.Error("same-session runner entered while first call held")
		}
		unblock()
		wg.Wait()

		mu.Lock()
		for i, err := range errs {
			if err != nil {
				t.Errorf("goroutine %d: unexpected error: %v", i, err)
			}
		}
		mu.Unlock()

		runner.mu.Lock()
		maxActive := runner.maxActive[t.Name()]
		callCount := len(runner.calls)
		runner.mu.Unlock()

		if callCount != n {
			t.Errorf("expected %d runner calls, got %d", n, callCount)
		}
		if maxActive > 1 {
			t.Errorf("detected %d concurrent calls for the same session; expected serialized execution (max 1)", maxActive)
		}
	})
}

// TestDispatch_Concurrent_DifferentSessions verifies that 10 concurrent calls
// with unique session keys proceed in parallel.
func TestDispatch_Concurrent_DifferentSessions(t *testing.T) {
	t.Parallel()
	synctest.Test(t, func(t *testing.T) {
		entered := make(chan string, 10)
		release := make(chan struct{})
		var once sync.Once
		unblock := func() { once.Do(func() { close(release) }) }
		defer unblock()
		runner := &mockRunner{response: "ok", entered: entered, release: release}
		mgr := NewSessionManager(runner, nil, "model")

		const n = 10
		var wg sync.WaitGroup
		errs := make([]error, n)

		for i := 0; i < n; i++ {
			wg.Add(1)
			go func(idx int) {
				defer wg.Done()
				key := fmt.Sprintf("%s/session-%d", t.Name(), idx)
				_, err := mgr.Dispatch(context.Background(), key, "", "msg")
				errs[idx] = err
			}(i)
		}
		for i := 0; i < n; i++ {
			<-entered
		}
		runner.mu.Lock()
		if len(runner.activeCalls) != n {
			t.Errorf("active sessions = %d, want %d", len(runner.activeCalls), n)
		}
		runner.mu.Unlock()
		unblock()
		wg.Wait()

		for i, err := range errs {
			if err != nil {
				t.Errorf("goroutine %d: unexpected error: %v", i, err)
			}
		}

		runner.mu.Lock()
		callCount := len(runner.calls)
		runner.mu.Unlock()

		if callCount != n {
			t.Errorf("expected %d runner calls, got %d", n, callCount)
		}
	})
}

// TestDispatch_LockMap_Stability verifies that after 1000 sequential unique sessions,
// the internal lock map is correctly cleaned up (no leaks).
func TestDispatch_LockMap_Stability(t *testing.T) {
	t.Parallel()
	runner := &mockRunner{response: "ok"}
	mgr := NewSessionManager(runner, nil, "model")

	const numSessions = 1000

	// Sequential dispatches with unique keys
	for i := 0; i < numSessions; i++ {
		key := fmt.Sprintf("stability-session-%d", i)
		if _, err := mgr.Dispatch(context.Background(), key, "", "msg"); err != nil {
			t.Fatalf("session %d failed: %v", i, err)
		}
	}

	// After all sessions complete, allLocks should be empty for these keys
	metrics := GetLockMetrics()
	count := 0
	for key := range metrics {
		if strings.HasPrefix(key, "stability-session-") {
			count++
		}
	}

	if count != 0 {
		t.Errorf("expected 0 stability-test locks remaining in map, found %d", count)
	}
}

func TestSessionManagerStress_WithStore(t *testing.T) {
	t.Parallel()
	runner := &mockRunner{response: "ok"}
	store := newMockStore()
	mgr := NewSessionManager(runner, store, "model")

	const n = 20
	var wg sync.WaitGroup
	errs := make([]error, n)

	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			_, err := mgr.Dispatch(context.Background(), "shared-key", "", "msg")
			errs[idx] = err
		}(i)
	}
	wg.Wait()

	for i, err := range errs {
		if err != nil {
			t.Errorf("goroutine %d: unexpected error: %v", i, err)
		}
	}

	store.mu.Lock()
	saveCalls := store.saveCalls
	store.mu.Unlock()

	if saveCalls != n {
		t.Errorf("expected %d store.saveCalls, got %d", n, saveCalls)
	}
}
