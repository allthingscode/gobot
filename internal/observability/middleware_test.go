//nolint:testpackage // in-package test, consistent with otel_test.go in this package
package observability

import (
	"context"
	"errors"
	"strings"
	"testing"
)

// newTestProvider returns a real Provider in its no-op configuration (empty OTLP
// endpoint), so StartSpan/RecordToolDuration/RecordTokens are exercised but inert.
// The no-op path returns before touching global OTel state, so tests stay parallel-safe.
func newTestProvider(t *testing.T) *Provider {
	t.Helper()
	p, err := NewProvider(Config{})
	if err != nil {
		t.Fatalf("NewProvider: %v", err)
	}
	return p
}

var errSentinel = errors.New("sentinel failure")

// isVerbatimSentinel asserts the error is the sentinel itself (identity), proving the
// nil-provider path returned the cause WITHOUT wrapping. errors.Is would be wrong here.
//
//nolint:errorlint // intentional identity check for the verbatim-passthrough contract
func isVerbatimSentinel(err error) bool { return err == errSentinel }

// assertWrapped checks the error is prefixed with the operation tag and still unwraps to the cause.
func assertWrapped(t *testing.T, err error, prefix string) {
	t.Helper()
	if err == nil || !strings.HasPrefix(err.Error(), prefix) {
		t.Errorf("want prefix %q, got %v", prefix, err)
		return
	}
	if !errors.Is(err, errSentinel) {
		t.Errorf("wrapped error does not unwrap to sentinel: %v", err)
	}
}

// errWrapper adapts each error-returning DispatchTracer method to a uniform shape.
type errWrapper struct {
	name   string
	prefix string
	call   func(d *DispatchTracer, fn func(context.Context) error) error
}

func errWrappers() []errWrapper {
	return []errWrapper{
		{"bot", "bot dispatch:", func(d *DispatchTracer, fn func(context.Context) error) error {
			return d.TraceBotDispatch(context.Background(), "s", fn)
		}},
		{"provider", "provider call:", func(d *DispatchTracer, fn func(context.Context) error) error {
			return d.TraceProviderCall(context.Background(), "s", 1, fn)
		}},
		{"google", "google maps.geocode call:", func(d *DispatchTracer, fn func(context.Context) error) error {
			return d.TraceGoogleCall(context.Background(), "maps", "geocode", fn)
		}},
		{"memory", "memory search (hybrid):", func(d *DispatchTracer, fn func(context.Context) error) error {
			return d.TraceMemorySearch(context.Background(), "hybrid", fn)
		}},
		{"consolidation", "memory consolidation:", func(d *DispatchTracer, fn func(context.Context) error) error {
			return d.TraceConsolidation(context.Background(), "s", fn)
		}},
	}
}

// With a nil provider, every error-returning wrapper calls fn and returns the error verbatim.
func TestDispatchTracer_ErrorReturning_NilProvider(t *testing.T) {
	t.Parallel()
	d := NewDispatchTracer(nil)
	for _, w := range errWrappers() {
		w := w
		t.Run(w.name, func(t *testing.T) {
			t.Parallel()
			called := false
			err := w.call(d, func(context.Context) error { called = true; return errSentinel })
			if !called {
				t.Fatalf("%s: fn not invoked", w.name)
			}
			if !isVerbatimSentinel(err) {
				t.Errorf("%s: want verbatim sentinel, got %v", w.name, err)
			}
		})
	}
}

// With a provider present, a failing wrapper wraps with its prefix (still unwrapping to the
// cause) and a succeeding wrapper returns nil.
func TestDispatchTracer_ErrorReturning_Provider(t *testing.T) {
	t.Parallel()
	d := NewDispatchTracer(newTestProvider(t))
	for _, w := range errWrappers() {
		w := w
		t.Run(w.name, func(t *testing.T) {
			t.Parallel()
			err := w.call(d, func(context.Context) error { return errSentinel })
			if err == nil || !strings.HasPrefix(err.Error(), w.prefix) {
				t.Errorf("%s: want prefix %q, got %v", w.name, w.prefix, err)
			}
			if !errors.Is(err, errSentinel) {
				t.Errorf("%s: wrapped error does not unwrap to sentinel: %v", w.name, err)
			}
			if err := w.call(d, func(context.Context) error { return nil }); err != nil {
				t.Errorf("%s success: %v", w.name, err)
			}
		})
	}
}

// TraceAgentDispatch with a nil provider returns the value and error verbatim.
func TestDispatchTracer_AgentDispatch_NilVerbatim(t *testing.T) {
	t.Parallel()
	got, err := NewDispatchTracer(nil).TraceAgentDispatch(context.Background(), "s", 3,
		func(context.Context) (string, error) { return "resp", errSentinel })
	if got != "resp" || !isVerbatimSentinel(err) {
		t.Errorf("agent nil: got %q/%v", got, err)
	}
}

// TraceAgentDispatch with a provider wraps a failing fn with its prefix.
func TestDispatchTracer_AgentDispatch_ProviderWrapped(t *testing.T) {
	t.Parallel()
	_, err := NewDispatchTracer(newTestProvider(t)).TraceAgentDispatch(context.Background(), "s", 2,
		func(context.Context) (string, error) { return "", errSentinel })
	assertWrapped(t, err, "agent dispatch:")
}

// TraceToolExecution with a nil provider returns the value and error verbatim.
func TestDispatchTracer_ToolExecution_NilVerbatim(t *testing.T) {
	t.Parallel()
	got, err := NewDispatchTracer(nil).TraceToolExecution(context.Background(), "s", "tool",
		func(context.Context) (string, error) { return "out", errSentinel })
	if got != "out" || !isVerbatimSentinel(err) {
		t.Errorf("tool nil: got %q/%v", got, err)
	}
}

// TraceToolExecution with a provider passes success through (exercising RecordToolDuration)
// and wraps errors with its prefix.
func TestDispatchTracer_ToolExecution_Provider(t *testing.T) {
	t.Parallel()
	d := NewDispatchTracer(newTestProvider(t))
	if got, err := d.TraceToolExecution(context.Background(), "s", "tool",
		func(context.Context) (string, error) { return "result", nil }); err != nil || got != "result" {
		t.Errorf("tool success: got %q/%v", got, err)
	}
	_, err := d.TraceToolExecution(context.Background(), "s", "tool",
		func(context.Context) (string, error) { return "", errSentinel })
	assertWrapped(t, err, "tool execution:")
}

// RecordTokens is a no-op that must be safe with a nil provider and with a present provider.
func TestDispatchTracer_RecordTokens_Safe(t *testing.T) {
	t.Parallel()
	NewDispatchTracer(nil).RecordTokens(context.Background(), 5)
	NewDispatchTracer(newTestProvider(t)).RecordTokens(context.Background(), 5)
}
