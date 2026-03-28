package agent

import (
	"context"
	"fmt"
	"sync"
	"testing"
)

func TestSessionManagerStress_SameSession(t *testing.T) {
	runner := &mockRunner{response: "ok"}
	mgr := NewSessionManager(runner, nil, "model")

	const n = 50
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
	callCount := len(runner.calls)
	runner.mu.Unlock()

	if callCount != n {
		t.Errorf("expected %d runner calls, got %d", n, callCount)
	}
}

func TestSessionManagerStress_MixedSessions(t *testing.T) {
	runner := &mockRunner{response: "ok"}
	mgr := NewSessionManager(runner, nil, "model")

	const n = 50
	var wg sync.WaitGroup
	errs := make([]error, n)

	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			key := fmt.Sprintf("session-%d", idx%10)
			_, err := mgr.Dispatch(context.Background(), key, "msg")
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
	callCount := len(runner.calls)
	runner.mu.Unlock()

	if callCount != n {
		t.Errorf("expected %d runner calls, got %d", n, callCount)
	}
}

func TestSessionManagerStress_WithStore(t *testing.T) {
	runner := &mockRunner{response: "ok"}
	store := newMockStore()
	mgr := NewSessionManager(runner, store, "model")

	const n = 50
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
