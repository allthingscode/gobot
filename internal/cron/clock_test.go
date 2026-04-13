//nolint:testpackage // requires unexported clock internals for testing
package cron

import (
	"sync"
	"time"
)

// fakeClock implements Clock for deterministic testing.
type fakeClock struct {
	mu     sync.Mutex
	now    time.Time
	waiter chan time.Time
}

func (f *fakeClock) Now() time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.now
}

func (f *fakeClock) After(_ time.Duration) <-chan time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	// Create a new channel for every call.
	f.waiter = make(chan time.Time, 1)
	return f.waiter
}

func (f *fakeClock) Sleep(_ time.Duration) {
	// Not used in the current poll loop.
}

// Advance moves the fake clock forward and triggers the waiter.
func (f *fakeClock) Advance(d time.Duration) {
	// Advance time first so Now() returns updated time before waiter triggers.
	f.mu.Lock()
	f.now = f.now.Add(d)
	w := f.waiter
	f.waiter = nil
	f.mu.Unlock()

	if w != nil {
		w <- f.now
	}
}

// HasWaiter returns true if someone is waiting on After().
func (f *fakeClock) HasWaiter() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.waiter != nil
}

// NewFakeClock returns a clock initialized to a fixed point in time.
func NewFakeClock(t time.Time) *fakeClock {
	return &fakeClock{
		now: t,
	}
}
