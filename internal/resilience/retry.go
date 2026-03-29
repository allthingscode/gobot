package resilience

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math/rand"
	"strings"
	"time"
)

// HTTPStatusError wraps an HTTP error response so IsRetryable can make
// status-code-based retry decisions.
type HTTPStatusError struct {
	StatusCode int
	Body       string
}

// Error implements the error interface.
func (e *HTTPStatusError) Error() string {
	return fmt.Sprintf("HTTP %d: %s", e.StatusCode, e.Body)
}

// RetryConfig controls retry behavior for Do.
type RetryConfig struct {
	MaxAttempts  int           // total attempts including the first; 0 treated as 3
	InitialDelay time.Duration // delay before the second attempt
	MaxDelay     time.Duration // upper bound on computed delay; 0 means no cap
	Multiplier   float64       // exponential backoff multiplier; 0 treated as 2.0
	JitterFactor float64       // fraction of delay added as ±jitter; 0 treated as 0.2
}

// DefaultRetryConfig is the standard retry configuration for gobot API calls:
// 3 attempts, 500ms initial delay, 10s cap, 2x multiplier, ±20% jitter.
var DefaultRetryConfig = RetryConfig{
	MaxAttempts:  3,
	InitialDelay: 500 * time.Millisecond,
	MaxDelay:     10 * time.Second,
	Multiplier:   2.0,
	JitterFactor: 0.2,
}

// Do executes fn up to cfg.MaxAttempts times, retrying when shouldRetry(err)
// returns true. Between attempts it sleeps for an exponentially increasing
// delay with ±cfg.JitterFactor jitter, capped at cfg.MaxDelay.
// ctx cancellation during a sleep returns ctx.Err() immediately.
// Each retry attempt is logged at Warn level; final failure is also logged.
func Do(ctx context.Context, cfg RetryConfig, shouldRetry func(error) bool, fn func() error) error {
	maxAttempts := cfg.MaxAttempts
	if maxAttempts <= 0 {
		maxAttempts = 3
	}
	multiplier := cfg.Multiplier
	if multiplier <= 0 {
		multiplier = 2.0
	}
	jitterFactor := cfg.JitterFactor
	if jitterFactor <= 0 {
		jitterFactor = 0.2
	}

	delay := cfg.InitialDelay
	var lastErr error
	for attempt := 0; attempt < maxAttempts; attempt++ {
		lastErr = fn()
		if lastErr == nil {
			if attempt > 0 {
				slog.Info("retry: succeeded after retry", "attempt", attempt+1)
			}
			return nil
		}
		if !shouldRetry(lastErr) {
			return lastErr
		}
		if attempt == maxAttempts-1 {
			break // last attempt — skip sleep
		}

		// Compute jittered delay: delay ± (delay * jitterFactor * rand[-1,1])
		jitterAmt := float64(delay) * jitterFactor * (2*rand.Float64() - 1)
		sleep := time.Duration(float64(delay) + jitterAmt)
		if sleep < 0 {
			sleep = 0
		}
		if cfg.MaxDelay > 0 && sleep > cfg.MaxDelay {
			sleep = cfg.MaxDelay
		}

		slog.Warn("retry: attempt failed, retrying",
			"attempt", attempt+1,
			"max_attempts", maxAttempts,
			"err", lastErr,
			"delay", sleep,
		)

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(sleep):
		}

		delay = time.Duration(float64(delay) * multiplier)
		if cfg.MaxDelay > 0 && delay > cfg.MaxDelay {
			delay = cfg.MaxDelay
		}
	}

	slog.Warn("retry: all attempts exhausted", "attempts", maxAttempts, "err", lastErr)
	return lastErr
}

// IsRetryable returns true for errors that are safe to retry:
//   - *HTTPStatusError with code 5xx or 429 (Too Many Requests)
//   - transient network/timeout errors detected by message pattern
//
// Returns false for non-retryable HTTP 4xx errors and nil.
func IsRetryable(err error) bool {
	if err == nil {
		return false
	}
	var httpErr *HTTPStatusError
	if errors.As(err, &httpErr) {
		code := httpErr.StatusCode
		return code == 429 || (code >= 500 && code < 600)
	}
	// Transient network/timeout patterns.
	msg := strings.ToLower(err.Error())
	for _, p := range []string{
		"timeout", "timed out", "deadline exceeded",
		"connection reset", "connection refused",
		"eof", "network", "temporary",
	} {
		if strings.Contains(msg, p) {
			return true
		}
	}
	return false
}
