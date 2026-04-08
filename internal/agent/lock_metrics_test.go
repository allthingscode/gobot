package agent

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestSessionLock_Metrics(t *testing.T) {
	t.Parallel()
	l := acquireLock("metrics-test-session", 0)
	defer l.release()

	// First lock
	err := l.Lock(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	_ = 1 + 1 // Non-empty section to satisfy staticcheck
	l.Unlock()

	metrics := GetLockMetrics()
	m, ok := metrics["metrics-test-session"]
	if !ok {
		t.Fatal("metrics not found for metrics-test-session")
	}

	if m.WaitCount != 0 {
		t.Errorf("expected 0 wait count, got %d", m.WaitCount)
	}

	// Wait, we need to test contention
	l2 := acquireLock("metrics-test-session", 0)
	defer l2.release()

	err = l.Lock(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	go func() {
		time.Sleep(50 * time.Millisecond)
		l.Unlock()
	}()

	err = l2.Lock(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	_ = 1 + 1 // Dummy operation to satisfy SA2001 (empty critical section)
	l2.Unlock()

	metrics = GetLockMetrics()
	m = metrics["metrics-test-session"]
	if m.ContentionCount < 1 {
		t.Errorf("expected contention count >= 1, got %d", m.ContentionCount)
	}
	if m.WaitCount < 1 {
		t.Errorf("expected wait count >= 1, got %d", m.WaitCount)
	}
	if m.MaxWaitTime == 0 {
		t.Error("expected MaxWaitTime > 0")
	}
}

func TestSessionLock_DeadlockError(t *testing.T) {
	t.Parallel()
	l := acquireLock("deadlock-test", 10*time.Millisecond)
	defer l.release()

	err := l.Lock(context.Background()) // First acquisition succeeds
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Second acquisition should timeout and return error
	err = l.Lock(context.Background())
	if err == nil {
		t.Error("expected error on deadlock, but got nil")
	}
}

func TestSessionLock_ContextCancellation(t *testing.T) {
	t.Parallel()
	l := acquireLock("cancel-test", 120*time.Second)
	defer l.release()

	// 1. Acquire lock to block others
	if err := l.Lock(context.Background()); err != nil {
		t.Fatalf("failed to acquire initial lock: %v", err)
	}

	// 2. Start a waiter with a cancellable context
	ctx, cancel := context.WithCancel(context.Background())
	errCh := make(chan error, 1)

	start := time.Now()
	go func() {
		errCh <- l.Lock(ctx)
	}()

	// 3. Cancel the context after a short delay
	time.Sleep(50 * time.Millisecond)
	cancel()

	// 4. Verify the waiter returns immediately with wrapped context.Canceled
	select {
	case err := <-errCh:
		elapsed := time.Since(start)
		if !errors.Is(err, context.Canceled) {
			t.Errorf("expected context.Canceled error, got: %v", err)
		}
		if elapsed > 500*time.Millisecond {
			t.Errorf("waiter took too long to return after cancellation: %v", elapsed)
		}
	case <-time.After(1 * time.Second):
		t.Fatal("timed out waiting for waiter to return after cancellation")
	}

	// 5. Cleanup: release initial lock
	l.Unlock()
}

func TestSessionLock_Lifecycle(t *testing.T) {
	t.Parallel()
	key := "lifecycle-test"

	// Initially no metrics
	if _, ok := GetLockMetrics()[key]; ok {
		t.Fatal("expected no metrics initially")
	}

	l1 := acquireLock(key, 0)
	if l1.refCount != 1 {
		t.Errorf("expected refCount 1, got %d", l1.refCount)
	}

	if _, ok := GetLockMetrics()[key]; !ok {
		t.Fatal("expected metrics after acquireLock")
	}

	l2 := acquireLock(key, 0)
	if l1 != l2 {
		t.Fatal("expected same lock object for same key")
	}
	if l1.refCount != 2 {
		t.Errorf("expected refCount 2, got %d", l1.refCount)
	}

	l1.release()
	if l1.refCount != 1 {
		t.Errorf("expected refCount 1 after first release, got %d", l1.refCount)
	}
	if _, ok := GetLockMetrics()[key]; !ok {
		t.Fatal("expected metrics still present after first release")
	}

	l2.release()
	if _, ok := GetLockMetrics()[key]; ok {
		t.Fatal("expected metrics to be removed after last release")
	}
}
