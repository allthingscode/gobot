package resilience

import (
	"context"
	"errors"
	"net/http"
	"testing"
	"time"
)

func TestDo_SuccessOnFirstAttempt(t *testing.T) {
	calls := 0
	cfg := RetryConfig{MaxAttempts: 3, InitialDelay: 0}
	err := Do(context.Background(), cfg, IsRetryable, func() error {
		calls++
		return nil
	})
	if err != nil {
		t.Fatalf("expected nil, got %v", err)
	}
	if calls != 1 {
		t.Errorf("expected 1 call, got %d", calls)
	}
}

func TestDo_RetryThenSucceed(t *testing.T) {
	calls := 0
	cfg := RetryConfig{MaxAttempts: 3, InitialDelay: 0}
	err := Do(context.Background(), cfg, IsRetryable, func() error {
		calls++
		if calls < 3 {
			return &HTTPStatusError{StatusCode: http.StatusServiceUnavailable}
		}
		return nil
	})
	if err != nil {
		t.Fatalf("expected nil after retry, got %v", err)
	}
	if calls != 3 {
		t.Errorf("expected 3 calls, got %d", calls)
	}
}

func TestDo_AllAttemptsFail(t *testing.T) {
	cfg := RetryConfig{MaxAttempts: 3, InitialDelay: 0}
	want := &HTTPStatusError{StatusCode: http.StatusInternalServerError, Body: "oops"}
	err := Do(context.Background(), cfg, IsRetryable, func() error {
		return want
	})
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	// err should be the same HTTPStatusError we returned.
	var httpErr *HTTPStatusError
	if !errors.As(err, &httpErr) || httpErr.StatusCode != http.StatusInternalServerError {
		t.Errorf("expected 500 HTTPStatusError, got %v", err)
	}
}

func TestDo_NonRetryableError(t *testing.T) {
	calls := 0
	cfg := RetryConfig{MaxAttempts: 3, InitialDelay: 0}
	err := Do(context.Background(), cfg, IsRetryable, func() error {
		calls++
		return &HTTPStatusError{StatusCode: http.StatusUnauthorized}
	})
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if calls != 1 {
		t.Errorf("expected 1 call (no retry on 401), got %d", calls)
	}
}

func TestDo_ContextCancelled(t *testing.T) {
	cfg := RetryConfig{MaxAttempts: 3, InitialDelay: 100 * time.Millisecond}
	ctx, cancel := context.WithCancel(context.Background())
	calls := 0
	go func() {
		time.Sleep(10 * time.Millisecond)
		cancel()
	}()
	err := Do(ctx, cfg, IsRetryable, func() error {
		calls++
		return &HTTPStatusError{StatusCode: http.StatusServiceUnavailable}
	})
	if !errors.Is(err, context.Canceled) {
		t.Errorf("expected context.Canceled, got %v", err)
	}
	if calls == 0 {
		t.Error("expected at least one call before cancellation")
	}
}

func TestDo_DefaultsAppliedWhenZero(t *testing.T) {
	// MaxAttempts=0 should default to 3 attempts.
	calls := 0
	cfg := RetryConfig{MaxAttempts: 0, InitialDelay: 0}
	_ = Do(context.Background(), cfg, IsRetryable, func() error {
		calls++
		return &HTTPStatusError{StatusCode: http.StatusInternalServerError}
	})
	if calls != 3 {
		t.Errorf("expected 3 calls with MaxAttempts=0 (default), got %d", calls)
	}
}

func TestIsRetryable(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want bool
	}{
		{"nil", nil, false},
		{"500", &HTTPStatusError{StatusCode: 500}, true},
		{"502", &HTTPStatusError{StatusCode: 502}, true},
		{"503", &HTTPStatusError{StatusCode: 503}, true},
		{"429", &HTTPStatusError{StatusCode: 429}, true},
		{"400", &HTTPStatusError{StatusCode: 400}, false},
		{"401", &HTTPStatusError{StatusCode: 401}, false},
		{"404", &HTTPStatusError{StatusCode: 404}, false},
		{"timeout string", errors.New("request timed out"), true},
		{"eof string", errors.New("unexpected EOF"), true},
		{"connection reset", errors.New("connection reset by peer"), true},
		{"non-retryable", errors.New("invalid argument"), false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := IsRetryable(tc.err); got != tc.want {
				t.Errorf("IsRetryable(%v) = %v, want %v", tc.err, got, tc.want)
			}
		})
	}
}

func TestHTTPStatusError_Error(t *testing.T) {
	e := &HTTPStatusError{StatusCode: 503, Body: "service unavailable"}
	want := "HTTP 503: service unavailable"
	if got := e.Error(); got != want {
		t.Errorf("Error() = %q, want %q", got, want)
	}
}

func TestHTTPStatusError_Error_EmptyBody(t *testing.T) {
	e := &HTTPStatusError{StatusCode: 429}
	want := "HTTP 429: "
	if got := e.Error(); got != want {
		t.Errorf("Error() = %q, want %q", got, want)
	}
}
