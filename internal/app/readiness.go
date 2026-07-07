package app

import (
	"sync"
	"time"
)

// Readiness is a concurrency-safe latch that distinguishes process readiness from
// liveness. It starts not-ready, flips ready once a critical listener has bound,
// and flips back to not-ready when shutdown begins so /ready reports 503 during the
// drain window while /health (liveness) still reports 200.
//
// Ready() returns a one-shot channel closed when readiness is first reached; it is
// used by startup orchestration to wait for the bind signal. IsReady() reflects the
// live state (including the shutdown flip) and backs the /ready handler.
type Readiness struct {
	mu            sync.Mutex
	ready         bool
	readySignaled bool
	readyAt       time.Time
	readyCh       chan struct{}
}

// NewReadiness returns a not-ready latch.
func NewReadiness() *Readiness {
	return &Readiness{readyCh: make(chan struct{})}
}

// SetReady marks the process ready. The first call closes the Ready() channel;
// later calls are no-ops on the channel.
func (r *Readiness) SetReady() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.ready = true
	if !r.readySignaled {
		r.readySignaled = true
		if r.readyAt.IsZero() {
			r.readyAt = time.Now()
		}
		close(r.readyCh)
	}
}

// SetNotReady marks the process not ready (e.g. shutdown started). The one-shot
// Ready() channel stays closed once tripped; IsReady reflects the live state.
func (r *Readiness) SetNotReady() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.ready = false
}

// IsReady reports the live readiness state.
func (r *Readiness) IsReady() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.ready
}

// Ready returns a channel closed the first time readiness is reached.
func (r *Readiness) Ready() <-chan struct{} {
	return r.readyCh
}

// ReadyAt returns the first timestamp at which readiness was reached.
func (r *Readiness) ReadyAt() (time.Time, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.readyAt.IsZero() {
		return time.Time{}, false
	}
	return r.readyAt, true
}
