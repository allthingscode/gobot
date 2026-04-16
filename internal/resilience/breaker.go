package resilience

import (
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/sony/gobreaker"
)

// ErrCircuitOpen is returned when a call is rejected because the circuit is open.
var ErrCircuitOpen = errors.New("circuit breaker: open")

// Breaker wraps a gobreaker.CircuitBreaker with slog state-change logging.
// Create with New; the zero value is not valid.
type Breaker struct {
	mu       sync.RWMutex
	cb       *gobreaker.CircuitBreaker
	settings gobreaker.Settings
}

// New creates a Breaker that trips to Open after maxConsecutiveFailures
// consecutive failures within countWindow, and attempts half-open recovery
// after openTimeout.
//
// All state transitions are logged at Warn level via slog.
func New(name string, maxConsecutiveFailures uint32, countWindow, openTimeout time.Duration) *Breaker {
	settings := gobreaker.Settings{
		Name:        name,
		MaxRequests: 1, // one canary request in half-open state
		Interval:    countWindow,
		Timeout:     openTimeout,
		ReadyToTrip: func(counts gobreaker.Counts) bool {
			return counts.ConsecutiveFailures >= maxConsecutiveFailures
		},
		OnStateChange: func(name string, from, to gobreaker.State) {
			slog.Warn("circuit breaker: state change",
				"name", name,
				"from", from.String(),
				"to", to.String(),
			)
		},
	}
	b := &Breaker{
		cb:       gobreaker.NewCircuitBreaker(settings),
		settings: settings,
	}
	Register(name, b)
	return b
}

// Execute calls fn through the circuit breaker.
// Returns ErrCircuitOpen (without calling fn) when the circuit is open.
// Any error returned by fn counts as a failure against the circuit.
func (b *Breaker) Execute(fn func() error) error {
	b.mu.RLock()
	cb := b.cb
	name := b.settings.Name
	b.mu.RUnlock()

	_, err := cb.Execute(func() (any, error) {
		err := fn()
		if err == nil {
			RecordSuccess(name)
		} else {
			RecordFailure(name)
		}
		return nil, err
	})
	if errors.Is(err, gobreaker.ErrOpenState) || errors.Is(err, gobreaker.ErrTooManyRequests) {
		RecordRejection(name)
		return ErrCircuitOpen
	}
	if err != nil {
		return fmt.Errorf("circuit breaker execute: %w", err)
	}
	return nil
}

// State returns the current circuit state as a string ("closed", "half-open", "open").
func (b *Breaker) State() string {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.cb.State().String()
}

// Reset clears the circuit breaker state, returning it to Closed.
func (b *Breaker) Reset() {
	b.mu.Lock()
	defer b.mu.Unlock()
	// Since gobreaker v1.0.0 doesn't have Reset(), we replace the instance.
	b.cb = gobreaker.NewCircuitBreaker(b.settings)
}

// Stop removes the breaker from the global registry.
func (b *Breaker) Stop() {
	b.mu.RLock()
	name := b.settings.Name
	b.mu.RUnlock()
	Unregister(name)
}
