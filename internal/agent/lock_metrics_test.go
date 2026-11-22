//nolint:testpackage // requires unexported mock types for testing
package agent

import (
	"context"
	"errors"
	"testing"
	"testing/synctest"
	"time"

	"github.com/stretchr/testify/assert"
)

func TestSessionLock_Metrics(t *testing.T) {
	t.Parallel()
	synctest.Test(t, checkSessionLockMetrics)
}

func TestSessionLock_DeadlockError(t *testing.T) {
	t.Parallel()
	synctest.Test(t, func(t *testing.T) {
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
	})
}

func TestSessionLock_ContextCancellation(t *testing.T) {
	t.Parallel()
	synctest.Test(t, func(t *testing.T) {
		l := acquireLock("cancel-test", 120*time.Second)
		defer l.release()

		// 1. Acquire lock to block others
		if err := l.Lock(context.Background()); err != nil {
			t.Fatalf("failed to acquire initial lock: %v", err)
		}

		// 2. Start a waiter with a cancellable context
		ctx, cancel := context.WithCancel(context.Background())
		errCh := make(chan error, 1)

		go func() {
			errCh <- l.Lock(ctx)
		}()

		// 3. Wait until waiter registers, then cancel
		synctest.Wait()
		if GetLockMetrics()["cancel-test"].WaitCount != 1 {
			t.Fatal("waiter did not register")
		}
		cancel()

		// 4. Verify the waiter returns immediately with wrapped context.Canceled
		select {
		case err := <-errCh:
			if !errors.Is(err, context.Canceled) {
				t.Errorf("expected context.Canceled error, got: %v", err)
			}

		case <-time.After(1 * time.Second):
			t.Fatal("timed out waiting for waiter to return after cancellation")
		}

		// 5. Cleanup: release initial lock
		l.Unlock()
	})
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

func TestLockStatus_CurrentHoldDurationAndStaleness(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 7, 14, 12, 0, 0, 0, time.UTC)

	tests := []struct {
		name      string
		status    LockStatus
		wantAge   time.Duration
		wantStale bool
	}{
		{
			name:      "unlocked",
			status:    LockStatus{},
			wantAge:   0,
			wantStale: false,
		},
		{
			name:      "locked without acquired at",
			status:    LockStatus{IsLocked: true},
			wantAge:   0,
			wantStale: false,
		},
		{
			name:      "locked below threshold",
			status:    LockStatus{IsLocked: true, AcquiredAt: now.Add(-30 * time.Second)},
			wantAge:   30 * time.Second,
			wantStale: false,
		},
		{
			name:      "locked above threshold",
			status:    LockStatus{IsLocked: true, AcquiredAt: now.Add(-2 * time.Minute)},
			wantAge:   2 * time.Minute,
			wantStale: true,
		},
		{
			name:      "future acquired at",
			status:    LockStatus{IsLocked: true, AcquiredAt: now.Add(time.Second)},
			wantAge:   0,
			wantStale: false,
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			if got := tt.status.CurrentHoldDuration(now); got != tt.wantAge {
				t.Fatalf("CurrentHoldDuration() = %s, want %s", got, tt.wantAge)
			}
			if got := tt.status.IsStale(now, StaleLockThreshold); got != tt.wantStale {
				t.Fatalf("IsStale() = %v, want %v", got, tt.wantStale)
			}
		})
	}
}

func checkSessionLockMetrics(t *testing.T) {
	t.Helper()
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

	errCh := make(chan error, 1)
	go func() {
		err := l2.Lock(context.Background())
		if err == nil {
			l2.Unlock()
		}
		errCh <- err
	}()

	synctest.Wait()
	time.Sleep(20 * time.Millisecond) // Advances the bubble clock while the waiter is held.
	l.Unlock()
	if err := <-errCh; err != nil {
		t.Fatalf("waiter failed: %v", err)
	}

	metrics = GetLockMetrics()
	m = metrics["metrics-test-session"]
	assert.Equal(t, 1, m.ContentionCount)
	assert.Equal(t, 1, m.WaitCount)
	assert.Equal(t, 20*time.Millisecond, m.MaxWaitTime)
	assert.Equal(t, 20*time.Millisecond, m.TotalWaitTime)
	assert.False(t, m.IsLocked)
}
