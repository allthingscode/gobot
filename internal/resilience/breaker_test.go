package resilience

import (
	"errors"
	"testing"
	"time"
)

func TestBreaker_ClosedByDefault(t *testing.T) {
	t.Parallel()
	b := New("test", 3, 10*time.Second, 1*time.Second)
	if got := b.State(); got != "closed" { //nolint:goconst // test fixture
		t.Fatalf("expected state %q, got %q", "closed", got)
	}
}

func TestBreaker_Execute_Success(t *testing.T) {
	t.Parallel()
	b := New("test", 3, 10*time.Second, 1*time.Second)
	err := b.Execute(func() error { return nil })
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
}

func TestBreaker_TripsAfterConsecutiveFailures(t *testing.T) {
	t.Parallel()
	b := New("test", 3, 60*time.Second, 1*time.Second)
	for i := 0; i < 3; i++ {
		_ = b.Execute(func() error { return errors.New("fail") })
	}
	if got := b.State(); got != "open" { //nolint:goconst // test fixture
		t.Fatalf("expected state %q after 3 failures, got %q", "open", got)
	}
}

func TestBreaker_OpenReturnsErrCircuitOpen(t *testing.T) {
	t.Parallel()
	b := New("test", 3, 60*time.Second, 1*time.Second)
	for i := 0; i < 3; i++ {
		_ = b.Execute(func() error { return errors.New("fail") })
	}
	err := b.Execute(func() error { return nil })
	if !errors.Is(err, ErrCircuitOpen) {
		t.Fatalf("expected ErrCircuitOpen, got %v", err)
	}
}

func TestBreaker_Execute_NonFatalError(t *testing.T) {
	t.Parallel()
	b := New("test", 5, 60*time.Second, 1*time.Second)
	err := b.Execute(func() error { return errors.New("transient") })
	if errors.Is(err, ErrCircuitOpen) {
		t.Fatal("expected non-ErrCircuitOpen error, but got ErrCircuitOpen")
	}
	if err == nil {
		t.Fatal("expected a non-nil error from fn, got nil")
	}
	if got := b.State(); got != "closed" { //nolint:goconst // test fixture
		t.Fatalf("expected state %q, got %q", "closed", got)
	}
}
