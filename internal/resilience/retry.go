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
	StatusCode int    // The HTTP response status code (e.g. 503).
	Body       string // The raw response body (if any).
}

// Error implements the error interface.
func (e *HTTPStatusError) Error() string {
	return fmt.Sprintf("HTTP %d: %s", e.StatusCode, e.Body)
}

// RetryConfig controls retry behavior for Do.
type RetryConfig struct {
	MaxAttempts  int           // Total attempts including the first; 0 treated as 3.
	InitialDelay time.Duration // Delay before the second attempt.
	MaxDelay     time.Duration // Upper bound on computed delay; 0 means no cap.
	Multiplier   float64       // Exponential backoff multiplier; 0 treated as 2.0.
	JitterFactor float64       // Fraction of delay added as ±jitter; 0 treated as 0.2.
}

// DefaultRetryConfig is the standard retry configuration for gobot API calls:
// 3 attempts, 500ms initial delay, 10s cap, 2x multiplier, ±20% jitter.
//nolint:gochecknoglobals // Package-level default retry config; immutable
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
	cfg = normalizeConfig(cfg)
	delay := cfg.InitialDelay
	var lastErr error

	for attempt := 1; attempt <= cfg.MaxAttempts; attempt++ {
		lastErr = fn()
		if lastErr == nil {
			logRetrySuccess(attempt)
			return nil
		}

		if !shouldRetry(lastErr) || attempt == cfg.MaxAttempts {
			break
		}

		sleep := calculateSleep(delay, cfg)
		logRetryAttempt(attempt, cfg.MaxAttempts, lastErr, sleep)

		if err := wait(ctx, sleep); err != nil {
			return err
		}

		delay = nextDelay(delay, cfg)
	}

	slog.Warn("retry: all attempts exhausted", "attempts", cfg.MaxAttempts, "err", lastErr)
	return lastErr
}

func normalizeConfig(cfg RetryConfig) RetryConfig {
	if cfg.MaxAttempts <= 0 {
		cfg.MaxAttempts = 3
	}
	if cfg.Multiplier <= 0 {
		cfg.Multiplier = 2.0
	}
	if cfg.JitterFactor <= 0 {
		cfg.JitterFactor = 0.2
	}
	return cfg
}

func calculateSleep(delay time.Duration, cfg RetryConfig) time.Duration {
	// Compute jittered delay: delay ± (delay * jitterFactor * rand[-1,1])
	// #nosec G404
	jitterAmt := float64(delay) * cfg.JitterFactor * (2*rand.Float64() - 1)
	sleep := time.Duration(float64(delay) + jitterAmt)
	if sleep < 0 {
		sleep = 0
	}
	if cfg.MaxDelay > 0 && sleep > cfg.MaxDelay {
		sleep = cfg.MaxDelay
	}
	return sleep
}

func nextDelay(current time.Duration, cfg RetryConfig) time.Duration {
	delay := time.Duration(float64(current) * cfg.Multiplier)
	if cfg.MaxDelay > 0 && delay > cfg.MaxDelay {
		delay = cfg.MaxDelay
	}
	return delay
}

func wait(ctx context.Context, sleep time.Duration) error {
	select {
	case <-ctx.Done():
		return fmt.Errorf("wait: %w", ctx.Err())
	case <-time.After(sleep):
		return nil
	}
}

func logRetrySuccess(attempt int) {
	if attempt > 1 {
		slog.Info("retry: succeeded after retry", "attempt", attempt)
	}
}

func logRetryAttempt(attempt, maxAttempts int, err error, sleep time.Duration) {
	slog.Warn("retry: attempt failed, retrying",
		"attempt", attempt,
		"max_attempts", maxAttempts,
		"err", err,
		"delay", sleep,
	)
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
