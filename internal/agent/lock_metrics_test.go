package agent

import (
	"testing"
	"time"
)

func TestSessionLock_Metrics(t *testing.T) {
	l := acquireLock("test-session")
	defer l.release()

	// First lock
	err := l.Lock()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	_ = 1 + 1 // Non-empty section to satisfy staticcheck
	l.Unlock()

	metrics := GetLockMetrics()
	m, ok := metrics["test-session"]
	if !ok {
		t.Fatal("metrics not found for test-session")
	}

	if m.WaitCount != 0 {
		t.Errorf("expected 0 wait count, got %d", m.WaitCount)
	}

	// Wait, we need to test contention
	l2 := acquireLock("test-session")
	defer l2.release()

	err = l.Lock()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	go func() {
		time.Sleep(50 * time.Millisecond)
		l.Unlock()
	}()

	err = l2.Lock()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	_ = 1 + 1 // Dummy operation to satisfy SA2001 (empty critical section)
	l2.Unlock()

	metrics = GetLockMetrics()
	m = metrics["test-session"]
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
	l := acquireLock("deadlock-test")
	defer l.release()
	// Make the timeout extremely short for the test
	l.deadlockDur = 10 * time.Millisecond

	err := l.Lock() // First acquisition succeeds
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Second acquisition should timeout and return error
	err = l.Lock()
	if err == nil {
		t.Error("expected error on deadlock, but got nil")
	}
}

func TestSessionLock_Lifecycle(t *testing.T) {
	key := "lifecycle-test"

	// Initially no metrics
	if _, ok := GetLockMetrics()[key]; ok {
		t.Fatal("expected no metrics initially")
	}

	l1 := acquireLock(key)
	if l1.refCount != 1 {
		t.Errorf("expected refCount 1, got %d", l1.refCount)
	}

	if _, ok := GetLockMetrics()[key]; !ok {
		t.Fatal("expected metrics after acquireLock")
	}

	l2 := acquireLock(key)
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