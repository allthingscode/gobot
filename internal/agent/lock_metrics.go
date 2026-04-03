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
	metricsMu  sync.RWMutex
	allMetrics = make(map[string]*LockStatus)
)

// GetLockMetrics returns a snapshot of all session lock metrics.
// Used by gobot doctor and debug endpoints.
func GetLockMetrics() map[string]LockStatus {
	metricsMu.RLock()
	defer metricsMu.RUnlock()

	snapshot := make(map[string]LockStatus, len(allMetrics))
	for k, v := range allMetrics {
		snapshot[k] = *v
	}
	return snapshot
}

// updateMetrics safely updates the metrics for a specific session.
func updateMetrics(sessionKey string, fn func(*LockStatus)) {
	metricsMu.Lock()
	defer metricsMu.Unlock()

	s, ok := allMetrics[sessionKey]
	if !ok {
		s = &LockStatus{SessionKey: sessionKey}
		allMetrics[sessionKey] = s
	}
	fn(s)
}

// sessionLock wraps a mutex with metrics and timeout capability.
type sessionLock struct {
	mu         sync.Mutex
	sessionKey string
}

// Lock acquires the lock, tracking metrics and panicking on deadlock (30s timeout).
// It also logs a warning if acquisition takes longer than 5s.
func (l *sessionLock) Lock() {
	start := time.Now()

	// Track that we are waiting
	updateMetrics(l.sessionKey, func(s *LockStatus) {
		if s.IsLocked {
			s.WaitCount++
			s.ContentionCount++
		}
	})

	locked := make(chan struct{})
	go func() {
		l.mu.Lock()
		close(locked)
	}()

	select {
	case <-locked:
		elapsed := time.Since(start)
		updateMetrics(l.sessionKey, func(s *LockStatus) {
			s.IsLocked = true
			s.AcquiredAt = time.Now()
			s.TotalWaitTime += elapsed
			if elapsed > s.MaxWaitTime {
				s.MaxWaitTime = elapsed
			}
			// Capture stack trace of holder (first 1KB is usually enough for the top of the stack)
			buf := make([]byte, 1024)
			n := runtime.Stack(buf, false)
			s.HolderStack = string(buf[:n])
		})
		if elapsed > 5*time.Second {
			slog.Warn("LOCK CONTENTION", "session", l.sessionKey, "wait_time", elapsed)
		}
	case <-time.After(30 * time.Second):
		buf := make([]byte, 64*1024)
		n := runtime.Stack(buf, true)
		panic("DEADLOCK DETECTED for session " + l.sessionKey + "\n\n" + string(buf[:n]))
	}
}

// Unlock releases the lock and records the hold duration.
func (l *sessionLock) Unlock() {
	updateMetrics(l.sessionKey, func(s *LockStatus) {
		if s.IsLocked {
			s.TotalHoldTime += time.Since(s.AcquiredAt)
			s.IsLocked = false
			s.HolderStack = ""
		}
	})
	l.mu.Unlock()
}
