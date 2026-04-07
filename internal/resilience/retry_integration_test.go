package resilience

import (
	"context"
	"errors"
	"net/http"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/testutil"
)

func TestRetryIntegration_5xxFailures(t *testing.T) {
	t.Parallel()
	fs := testutil.NewFaultyServer()
	defer fs.Close()

	fs.Sequence = []testutil.ResponseAction{
		{StatusCode: http.StatusInternalServerError},
		{StatusCode: http.StatusBadGateway},
		{StatusCode: http.StatusOK},
	}

	cfg := RetryConfig{
		MaxAttempts:  3,
		InitialDelay: 10 * time.Millisecond,
		Multiplier:   1.0,
		JitterFactor: 0.1,
	}

	err := Do(context.Background(), cfg, IsRetryable, func() error {
		req, _ := http.NewRequestWithContext(context.Background(), "GET", fs.URL, http.NoBody)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return err
		}
		defer resp.Body.Close()
		if resp.StatusCode >= 400 {
			return &HTTPStatusError{StatusCode: resp.StatusCode}
		}
		return nil
	})
	if err != nil {
		t.Fatalf("expected success after retries, got %v", err)
	}

	if fs.RequestCount != 3 {
		t.Errorf("expected 3 requests, got %d", fs.RequestCount)
	}
}

func TestRetryIntegration_NoRetryOn4xx(t *testing.T) {
	t.Parallel()
	fs := testutil.NewFaultyServer()
	defer fs.Close()

	fs.Sequence = []testutil.ResponseAction{
		{StatusCode: http.StatusNotFound},
		{StatusCode: http.StatusOK},
	}

	cfg := RetryConfig{
		MaxAttempts:  3,
		InitialDelay: 10 * time.Millisecond,
	}

	err := Do(context.Background(), cfg, IsRetryable, func() error {
		req, _ := http.NewRequestWithContext(context.Background(), "GET", fs.URL, http.NoBody)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return err
		}
		defer resp.Body.Close()
		if resp.StatusCode >= 400 {
			return &HTTPStatusError{StatusCode: resp.StatusCode}
		}
		return nil
	})

	if err == nil {
		t.Fatal("expected error, got nil")
	}

	var httpErr *HTTPStatusError
	if !errors.As(err, &httpErr) || httpErr.StatusCode != http.StatusNotFound {
		t.Errorf("expected 404 error, got %v", err)
	}

	if fs.RequestCount != 1 {
		t.Errorf("expected 1 request (no retry on 404), got %d", fs.RequestCount)
	}
}

func TestRetryIntegration_ExponentialBackoffTiming(t *testing.T) {
	t.Parallel()
	fs := testutil.NewFaultyServer()
	defer fs.Close()

	fs.Sequence = []testutil.ResponseAction{
		{StatusCode: http.StatusInternalServerError},
		{StatusCode: http.StatusInternalServerError},
		{StatusCode: http.StatusOK},
	}

	cfg := RetryConfig{
		MaxAttempts:  3,
		InitialDelay: 100 * time.Millisecond,
		Multiplier:   2.0,
		JitterFactor: 0.05, // small jitter for timing test
	}

	start := time.Now()
	err := Do(context.Background(), cfg, IsRetryable, func() error {
		req, _ := http.NewRequestWithContext(context.Background(), "GET", fs.URL, http.NoBody)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return err
		}
		defer resp.Body.Close()
		if resp.StatusCode >= 400 {
			return &HTTPStatusError{StatusCode: resp.StatusCode}
		}
		return nil
	})
	elapsed := time.Since(start)

	if err != nil {
		t.Fatalf("expected success, got %v", err)
	}

	// Expected delay:
	// 1st retry: ~100ms
	// 2nd retry: ~200ms
	// Total wait time: ~300ms
	// Tolerance: 25% (due to jitter and OS scheduling)
	minWait := 225 * time.Millisecond
	maxWait := 375 * time.Millisecond

	if elapsed < minWait || elapsed > maxWait {
		t.Errorf("total elapsed time %v out of expected range [%v, %v]", elapsed, minWait, maxWait)
	}
}

func TestRetryIntegration_CircuitBreakerTripping(t *testing.T) {
	t.Parallel()
	fs := testutil.NewFaultyServer()
	defer fs.Close()

	// Fail every request
	fs.FailureRate = 1.0
	fs.FailureCodes = []int{http.StatusInternalServerError}

	// Circuit breaker: trip after 2 failures
	cb := New("test-breaker", 2, 10*time.Second, 100*time.Millisecond)
	defer cb.Stop()

	cfg := RetryConfig{
		MaxAttempts:  2,
		InitialDelay: 0,
	}

	// First call: 2 attempts, both fail. CB sees 1 failure.
	_ = cb.Execute(func() error {
		return Do(context.Background(), cfg, IsRetryable, func() error {
			req, _ := http.NewRequestWithContext(context.Background(), http.MethodGet, fs.URL, http.NoBody)
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				return err
			}
			defer resp.Body.Close()
			if resp.StatusCode >= 400 {
				return &HTTPStatusError{StatusCode: resp.StatusCode}
			}
			return nil
		})
	})

	// Second call: 2 attempts, both fail. CB sees 2nd failure and trips.
	err := cb.Execute(func() error {
		return Do(context.Background(), cfg, IsRetryable, func() error {
			req, _ := http.NewRequestWithContext(context.Background(), http.MethodGet, fs.URL, http.NoBody)
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				return err
			}
			defer resp.Body.Close()
			if resp.StatusCode >= 400 {
				return &HTTPStatusError{StatusCode: resp.StatusCode}
			}
			return nil
		})
	})

	if err == nil {
		t.Fatal("expected error from second execution, got nil")
	}

	if cb.State() != "open" {
		t.Errorf("expected circuit breaker to be open, got %s", cb.State())
	}

	// Second call: should fail immediately with ErrCircuitOpen
	err = cb.Execute(func() error {
		return nil // won't be called
	})

	if !errors.Is(err, ErrCircuitOpen) {
		t.Errorf("expected ErrCircuitOpen, got %v", err)
	}
}

func TestRetryIntegration_RecoveryAfterNetworkReturns(t *testing.T) {
	t.Parallel()
	fs := testutil.NewFaultyServer()
	defer fs.Close()

	// Initial state: network down (dropped connections)
	fs.DropConnection = true
	fs.FailureRate = 1.0

	// Circuit breaker: trip after 2 failures
	cb := New("recovery-breaker", 2, 10*time.Second, 100*time.Millisecond)
	defer cb.Stop()

	// Fail twice to trip CB
	for i := 0; i < 2; i++ {
		_ = cb.Execute(func() error {
			req, _ := http.NewRequestWithContext(context.Background(), http.MethodGet, fs.URL, http.NoBody)
			_, err := http.DefaultClient.Do(req)
			return err
		})
	}

	if cb.State() != "open" {
		t.Fatalf("expected CB to be open, got %s", cb.State())
	}

	// Wait for CB to enter half-open state
	time.Sleep(150 * time.Millisecond)

	// Restore network
	fs.Update(func(f *testutil.FaultyServer) {
		f.DropConnection = false
		f.FailureRate = 0.0
	})

	// CB should be in half-open state now (internally in gobreaker)
	// Execute one successful call to close it
	err := cb.Execute(func() error {
		req, _ := http.NewRequestWithContext(context.Background(), http.MethodGet, fs.URL, http.NoBody)
		resp, innerErr := http.DefaultClient.Do(req)
		if innerErr != nil {
			return innerErr
		}
		resp.Body.Close()
		return nil
	})
	if err != nil {
		t.Fatalf("expected success on recovery, got %v", err)
	}

	if cb.State() != "closed" {
		t.Errorf("expected CB to be closed after successful recovery call, got %s", cb.State())
	}
}
