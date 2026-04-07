package agent

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"
)

// TestDispatch_Concurrent_SameSession verifies that 10 concurrent calls
// with the same session key are correctly serialized (no overlaps).
func TestDispatch_Concurrent_SameSession(t *testing.T) {
	runner := &mockRunner{
		response: "ok",
		delay:    50 * time.Millisecond, // Increase chance of seeing overlaps if locking failed
	}
	mgr := NewSessionManager(runner, nil, "model")

	const n = 10
	var wg sync.WaitGroup
	errs := make([]error, n)

	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			_, err := mgr.Dispatch(context.Background(), "shared-key", "msg")
			errs[idx] = err
		}(i)
	}
	wg.Wait()

	for i, err := range errs {
		if err != nil {
			t.Errorf("goroutine %d: unexpected error: %v", i, err)
		}
	}

	runner.mu.Lock()
	maxActive := runner.maxActive["shared-key"]
	callCount := len(runner.calls)
	runner.mu.Unlock()

	if callCount != n {
		t.Errorf("expected %d runner calls, got %d", n, callCount)
	}
	if maxActive > 1 {
		t.Errorf("detected %d concurrent calls for the same session; expected serialized execution (max 1)", maxActive)
	}
}

// TestDispatch_Concurrent_DifferentSessions verifies that 10 concurrent calls
// with unique session keys proceed in parallel.
func TestDispatch_Concurrent_DifferentSessions(t *testing.T) {
	runner := &mockRunner{
		response: "ok",
		delay:    100 * time.Millisecond,
	}
	mgr := NewSessionManager(runner, nil, "model")

	const n = 10
	var wg sync.WaitGroup
	errs := make([]error, n)

	start := time.Now()
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			key := fmt.Sprintf("session-%d", idx)
			_, err := mgr.Dispatch(context.Background(), key, "msg")
			errs[idx] = err
		}(i)
	}
	wg.Wait()
	duration := time.Since(start)

	for i, err := range errs {
		if err != nil {
			t.Errorf("goroutine %d: unexpected error: %v", i, err)
		}
	}

	// If they were serialized, duration would be >= n * delay (10 * 100ms = 1s).
	// If parallel, it should be slightly more than 100ms.
	if duration >= 500*time.Millisecond {
		t.Errorf("execution took %v; expected parallel execution (< 500ms for 10x100ms parallel tasks)", duration)
	}

	runner.mu.Lock()
	callCount := len(runner.calls)
	runner.mu.Unlock()

	if callCount != n {
		t.Errorf("expected %d runner calls, got %d", n, callCount)
	}
}

// TestDispatch_LockMap_Stability verifies that after 1000 sequential unique sessions,
// the internal lock map is correctly cleaned up (no leaks).
func TestDispatch_LockMap_Stability(t *testing.T) {
	runner := &mockRunner{response: "ok"}
	mgr := NewSessionManager(runner, nil, "model")

	const numSessions = 1000

	// Sequential dispatches with unique keys
	for i := 0; i < numSessions; i++ {
		key := fmt.Sprintf("stability-session-%d", i)
		if _, err := mgr.Dispatch(context.Background(), key, "msg"); err != nil {
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
			_, err := mgr.Dispatch(context.Background(), "shared-key", "msg")
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
