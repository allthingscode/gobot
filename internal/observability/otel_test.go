package observability

import (
	"context"
	"errors"
	"testing"
	"time"

	"go.opentelemetry.io/otel/attribute"
)

// TestNewProvider_NoEndpoint creates a no-op provider when endpoint is empty.
func TestNewProvider_NoEndpoint(t *testing.T) {
	t.Parallel()
	p, err := NewProvider(Config{})
	if err != nil {
		t.Fatalf("NewProvider() error = %v", err)
	}
	if p == nil {
		t.Fatal("NewProvider() returned nil")
	}
	defer p.Shutdown(context.Background())

	// Should have a valid tracer even in no-op mode
	if p.Tracer() == nil {
		t.Error("Tracer() returned nil")
	}
}

// TestProvider_StartSpan creates spans with attributes.
func TestProvider_StartSpan(t *testing.T) {
	t.Parallel()
	p, err := NewProvider(Config{})
	if err != nil {
		t.Fatalf("NewProvider() error = %v", err)
	}
	defer p.Shutdown(context.Background())

	ctx, span := p.StartSpan(context.Background(), "test.span",
		attribute.String("key", "value"),
	)
	if ctx == nil {
		t.Error("StartSpan() returned nil context")
	}
	if span == nil {
		t.Error("StartSpan() returned nil span")
	}
	span.End()
}

// TestDispatchTracer_TraceBotDispatch traces bot dispatch operations.
func TestDispatchTracer_TraceBotDispatch(t *testing.T) {
	t.Parallel()
	p, _ := NewProvider(Config{})
	defer p.Shutdown(context.Background())

	dt := NewDispatchTracer(p)

	called := false
	err := dt.TraceBotDispatch(context.Background(), "session-123", func(ctx context.Context) error {
		called = true
		return nil
	})

	if !called {
		t.Error("TraceBotDispatch did not call the function")
	}
	if err != nil {
		t.Errorf("TraceBotDispatch() error = %v", err)
	}
}

// TestDispatchTracer_TraceBotDispatch_Error records errors.
func TestDispatchTracer_TraceBotDispatch_Error(t *testing.T) {
	t.Parallel()
	p, _ := NewProvider(Config{})
	defer p.Shutdown(context.Background())

	dt := NewDispatchTracer(p)

	wantErr := errors.New("dispatch failed")
	err := dt.TraceBotDispatch(context.Background(), "session-123", func(ctx context.Context) error {
		return wantErr
	})

	if err != wantErr {
		t.Errorf("TraceBotDispatch() error = %v, want %v", err, wantErr)
	}
}

// TestDispatchTracer_TraceAgentDispatch traces agent dispatch.
func TestDispatchTracer_TraceAgentDispatch(t *testing.T) {
	t.Parallel()
	p, _ := NewProvider(Config{})
	defer p.Shutdown(context.Background())

	dt := NewDispatchTracer(p)

	response, err := dt.TraceAgentDispatch(context.Background(), "session-456", 5, func(ctx context.Context) (string, error) {
		return "hello world", nil
	})

	if err != nil {
		t.Errorf("TraceAgentDispatch() error = %v", err)
	}
	if response != "hello world" {
		t.Errorf("TraceAgentDispatch() response = %v, want %v", response, "hello world")
	}
}

// TestDispatchTracer_TraceGeminiCall traces Gemini API calls.
func TestDispatchTracer_TraceGeminiCall(t *testing.T) {
	t.Parallel()
	p, _ := NewProvider(Config{})
	defer p.Shutdown(context.Background())

	dt := NewDispatchTracer(p)

	err := dt.TraceGeminiCall(context.Background(), "session-789", 2, func(ctx context.Context) error {
		return nil
	})

	if err != nil {
		t.Errorf("TraceGeminiCall() error = %v", err)
	}
}

// TestDispatchTracer_TraceToolExecution traces tool execution.
func TestDispatchTracer_TraceToolExecution(t *testing.T) {
	t.Parallel()
	p, _ := NewProvider(Config{})
	defer p.Shutdown(context.Background())

	dt := NewDispatchTracer(p)

	result, err := dt.TraceToolExecution(context.Background(), "session-abc", "shell", func(ctx context.Context) (string, error) {
		time.Sleep(1 * time.Millisecond) // Ensure some duration
		return "output", nil
	})

	if err != nil {
		t.Errorf("TraceToolExecution() error = %v", err)
	}
	if result != "output" {
		t.Errorf("TraceToolExecution() result = %v, want %v", result, "output")
	}
}

// TestDispatchTracer_TraceToolExecution_Error records tool errors.
func TestDispatchTracer_TraceToolExecution_Error(t *testing.T) {
	t.Parallel()
	p, _ := NewProvider(Config{})
	defer p.Shutdown(context.Background())

	dt := NewDispatchTracer(p)

	wantErr := errors.New("tool failed")
	_, err := dt.TraceToolExecution(context.Background(), "session-abc", "shell", func(ctx context.Context) (string, error) {
		return "", wantErr
	})

	if err != wantErr {
		t.Errorf("TraceToolExecution() error = %v, want %v", err, wantErr)
	}
}

// TestProvider_RecordTokens records token metrics without error.
func TestProvider_RecordTokens(t *testing.T) {
	t.Parallel()
	p, _ := NewProvider(Config{})
	defer p.Shutdown(context.Background())

	// Should not panic in no-op mode
	p.RecordTokens(context.Background(), 100)
}

// TestProvider_RecordToolDuration records duration metrics without error.
func TestProvider_RecordToolDuration(t *testing.T) {
	t.Parallel()
	p, _ := NewProvider(Config{})
	defer p.Shutdown(context.Background())

	// Should not panic in no-op mode
	p.RecordToolDuration(context.Background(), 100*time.Millisecond)
}

// TestProvider_Shutdown is safe to call multiple times.
func TestProvider_Shutdown(t *testing.T) {
	t.Parallel()
	p, _ := NewProvider(Config{})

	ctx := context.Background()
	if err := p.Shutdown(ctx); err != nil {
		t.Errorf("Shutdown() error = %v", err)
	}
	// Second shutdown should be safe
	if err := p.Shutdown(ctx); err != nil {
		t.Errorf("Shutdown() second call error = %v", err)
	}
}

// TestDispatchTracer_NilProvider handles nil provider gracefully.
func TestDispatchTracer_NilProvider(t *testing.T) {
	t.Parallel()
	dt := NewDispatchTracer(nil)
	if dt == nil {
		t.Error("NewDispatchTracer(nil) should return non-nil")
	}

	// Should not panic
	err := dt.TraceBotDispatch(context.Background(), "session", func(ctx context.Context) error {
		return nil
	})
	if err != nil {
		t.Errorf("TraceBotDispatch() error = %v", err)
	}
}
