package agent

import (
	"runtime"
	"sync"
	"testing"
	"time"
)

func TestSessionLock_Metrics(t *testing.T) {
	l := newSessionLock("test-session")

	// First lock
	l.Lock()
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

	// Test contention
	var wg sync.WaitGroup
	wg.Add(1)

	started := make(chan struct{})
	unlocked := make(chan struct{})

	l.Lock()

	go func() {
		close(started)
		l.Lock() // Should wait
		_ = 1 + 1
		l.Unlock()
		close(unlocked)
		wg.Done()
	}()

	// Wait for goroutine to start
	<-started

	// Deterministically wait for contention count to increase
	for {
		l.metricsMu.RLock()
		wc := l.metrics.WaitCount
		l.metricsMu.RUnlock()
		if wc > 0 {
			break
		}
		runtime.Gosched()
	}

	// Wait past the Windows timer resolution (~15.6ms) to ensure MaxWaitTime > 0.
	// Note: This is NOT for goroutine coordination, only for time measurement.
	time.Sleep(20 * time.Millisecond)

	l.Unlock()
	<-unlocked
	wg.Wait()

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

func TestSessionLock_DeadlockPanic(t *testing.T) {
	l := newSessionLock("deadlock-test")
	// Make the timeout extremely short for the test
	l.deadlockDur = 10 * time.Millisecond

	l.Lock() // First acquisition succeeds

	panicked := false
	func() {
		defer func() {
			if r := recover(); r != nil {
				panicked = true
			}
		}()
		l.Lock() // Second acquisition should timeout and panic
	}()

	if !panicked {
		t.Error("expected deadlock panic, but didn't happen")
	}
}
