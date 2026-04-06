package cron

import (
	"time"
)

// Clock defines the interface for time-based operations.
// Ported from C-021 specification to enable deterministic testing.
type Clock interface {
	Now() time.Time
	After(d time.Duration) <-chan time.Time
	Sleep(d time.Duration)
}

// realClock implements Clock using the standard time package.
type realClock struct{}

func (realClock) Now() time.Time                         { return time.Now() }
func (realClock) After(d time.Duration) <-chan time.Time { return time.After(d) }
func (realClock) Sleep(d time.Duration)                  { time.Sleep(d) }

// RealClock returns a production-ready clock implementation.
func RealClock() Clock {
	return &realClock{}
}
