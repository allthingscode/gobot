package agent

import (
	"log/slog"
	"runtime"
	"sync"
	"time"
)

// LockStatus represents the current state and historical metrics of a session lock.
type LockStatus struct {
	SessionKey      string        `json:"session_key"`
	IsLocked        bool          `json:"is_locked"`
	HolderStack     string        `json:"holder_stack,omitempty"`
	AcquiredAt      time.Time     `json:"acquired_at,omitempty"`
	WaitCount       int           `json:"wait_count"`
	TotalWaitTime   time.Duration `json:"total_wait_time"`
	TotalHoldTime   time.Duration `json:"total_hold_time"`
	ContentionCount int           `json:"contention_count"`
	MaxWaitTime     time.Duration `json:"max_wait_time"`
}

var (
	allLocks   = make(map[string]*sessionLock)
	allLocksMu sync.Mutex
)

// GetLockMetrics returns a snapshot of all session lock metrics.
// Used by gobot doctor and debug endpoints.
func GetLockMetrics() map[string]LockStatus {
	snapshot := make(map[string]LockStatus)
	allLocksMu.Lock()
	defer allLocksMu.Unlock()

	for key, l := range allLocks {
		l.metricsMu.RLock()
		snapshot[key] = l.metrics
		l.metricsMu.RUnlock()
	}
	return snapshot
}

// sessionLock wraps a channel-based lock with metrics, timeout, and reference counting.
type sessionLock struct {
	sessionKey  string
	ch          chan struct{}
	metrics     LockStatus
	metricsMu   sync.RWMutex
	deadlockDur time.Duration
	refCount    int
}

// acquireLock gets or creates a sessionLock for the given key and increments its reference count.
// Must be called via SessionManager to ensure proper cleanup.
func acquireLock(key string) *sessionLock {
	allLocksMu.Lock()
	defer allLocksMu.Unlock()

	l, ok := allLocks[key]
	if !ok {
		l = &sessionLock{
			sessionKey:  key,
			ch:          make(chan struct{}, 1),
			metrics:     LockStatus{SessionKey: key},
			deadlockDur: 30 * time.Second,
		}
		l.ch <- struct{}{}
		allLocks[key] = l
	}
	l.refCount++
	return l
}

// release decrements the reference count and removes the lock from the global map if it hits zero.
func (l *sessionLock) release() {
	allLocksMu.Lock()
	defer allLocksMu.Unlock()

	l.refCount--
	if l.refCount <= 0 {
		delete(allLocks, l.sessionKey)
	}
}

// Lock acquires the lock, tracking metrics and panicking on deadlock.
func (l *sessionLock) Lock() {
	start := time.Now()

	l.metricsMu.Lock()
	if l.metrics.IsLocked {
		l.metrics.WaitCount++
		l.metrics.ContentionCount++
	}
	l.metricsMu.Unlock()

	select {
	case <-l.ch:
		elapsed := time.Since(start)
		l.metricsMu.Lock()
		l.metrics.IsLocked = true
		l.metrics.AcquiredAt = time.Now()
		l.metrics.TotalWaitTime += elapsed
		if elapsed > l.metrics.MaxWaitTime {
			l.metrics.MaxWaitTime = elapsed
		}
		if elapsed > 5*time.Second {
			buf := make([]byte, 1024)
			n := runtime.Stack(buf, false)
			l.metrics.HolderStack = string(buf[:n])
			slog.Warn("LOCK CONTENTION", "session", l.sessionKey, "wait_time", elapsed)
		} else {
			l.metrics.HolderStack = ""
		}
		l.metricsMu.Unlock()
	case <-time.After(l.deadlockDur):
		buf := make([]byte, 64*1024)
		n := runtime.Stack(buf, true)
		panic("DEADLOCK DETECTED for session " + l.sessionKey + "\n\n" + string(buf[:n]))
	}
}

// Unlock releases the lock and records the hold duration.
func (l *sessionLock) Unlock() {
	l.metricsMu.Lock()
	if l.metrics.IsLocked {
		l.metrics.TotalHoldTime += time.Since(l.metrics.AcquiredAt)
		l.metrics.IsLocked = false
		l.metrics.HolderStack = ""
	}
	l.metricsMu.Unlock()

	l.ch <- struct{}{}
}
