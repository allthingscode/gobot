package resilience

import (
	"errors"
	"log/slog"
	"time"

	"github.com/sony/gobreaker"
)

// ErrCircuitOpen is returned when a call is rejected because the circuit is open.
var ErrCircuitOpen = errors.New("circuit breaker: open")

// Breaker wraps a gobreaker.CircuitBreaker with slog state-change logging.
// Create with New; the zero value is not valid.
type Breaker struct {
	cb *gobreaker.CircuitBreaker
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
	return &Breaker{cb: gobreaker.NewCircuitBreaker(settings)}
}

// Execute calls fn through the circuit breaker.
// Returns ErrCircuitOpen (without calling fn) when the circuit is open.
// Any error returned by fn counts as a failure against the circuit.
func (b *Breaker) Execute(fn func() error) error {
	_, err := b.cb.Execute(func() (any, error) {
		return nil, fn()
	})
	if errors.Is(err, gobreaker.ErrOpenState) || errors.Is(err, gobreaker.ErrTooManyRequests) {
		return ErrCircuitOpen
	}
	return err
}

// State returns the current circuit state as a string ("closed", "half-open", "open").
func (b *Breaker) State() string {
	return b.cb.State().String()
}
