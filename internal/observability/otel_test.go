package observability

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"strings"
	"testing"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
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
	defer func() { _ = p.Shutdown(context.Background()) }()

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
	defer func() { _ = p.Shutdown(context.Background()) }()

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
	defer func() { _ = p.Shutdown(context.Background()) }()

	dt := NewDispatchTracer(p)

	called := false
	err := dt.TraceBotDispatch(context.Background(), "session-123", func(_ context.Context) error {
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
	defer func() { _ = p.Shutdown(context.Background()) }()

	dt := NewDispatchTracer(p)

	wantErr := errors.New("dispatch failed")
	err := dt.TraceBotDispatch(context.Background(), "session-123", func(_ context.Context) error {
		return wantErr
	})

	if !errors.Is(err, wantErr) {
		t.Errorf("TraceBotDispatch() error = %v, want %v", err, wantErr)
	}
}

// TestDispatchTracer_TraceAgentDispatch traces agent dispatch.
func TestDispatchTracer_TraceAgentDispatch(t *testing.T) {
	t.Parallel()
	p, _ := NewProvider(Config{})
	defer func() { _ = p.Shutdown(context.Background()) }()

	dt := NewDispatchTracer(p)

	response, err := dt.TraceAgentDispatch(context.Background(), "session-456", 5, func(_ context.Context) (string, error) {
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
	defer func() { _ = p.Shutdown(context.Background()) }()

	dt := NewDispatchTracer(p)

	err := dt.TraceGeminiCall(context.Background(), "session-789", 2, func(_ context.Context) error {
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
	defer func() { _ = p.Shutdown(context.Background()) }()

	dt := NewDispatchTracer(p)

	result, err := dt.TraceToolExecution(context.Background(), "session-abc", "shell", func(_ context.Context) (string, error) {
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
	defer func() { _ = p.Shutdown(context.Background()) }()

	dt := NewDispatchTracer(p)

	wantErr := errors.New("tool failed")
	_, err := dt.TraceToolExecution(context.Background(), "session-abc", "shell", func(_ context.Context) (string, error) {
		return "", wantErr
	})

	if !errors.Is(err, wantErr) {
		t.Errorf("TraceToolExecution() error = %v, want %v", err, wantErr)
	}
}

// TestProvider_RecordTokens records token metrics without error.
func TestProvider_RecordTokens(t *testing.T) {
	t.Parallel()
	p, _ := NewProvider(Config{})
	defer func() { _ = p.Shutdown(context.Background()) }()

	// Should not panic in no-op mode
	p.RecordTokens(context.Background(), 100)
}

// TestProvider_RecordToolDuration records duration metrics without error.
func TestProvider_RecordToolDuration(t *testing.T) {
	t.Parallel()
	p, _ := NewProvider(Config{})
	defer func() { _ = p.Shutdown(context.Background()) }()

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
	err := dt.TraceBotDispatch(context.Background(), "session", func(_ context.Context) error {
		return nil
	})
	if err != nil {
		t.Errorf("TraceBotDispatch() error = %v", err)
	}
}

// TestNewSlogHandler_NoSpan passes through records unchanged when no span is active.
func TestNewSlogHandler_NoSpan(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	inner := slog.NewTextHandler(&buf, nil)
	h := NewSlogHandler(inner)

	logger := slog.New(h)
	logger.InfoContext(context.Background(), "hello")

	out := buf.String()
	if !strings.Contains(out, "hello") {
		t.Errorf("expected 'hello' in output, got: %s", out)
	}
	// No active span — trace_id/span_id should not appear
	if strings.Contains(out, "trace_id") {
		t.Errorf("unexpected trace_id in output without active span: %s", out)
	}
}

// TestNewSlogHandler_WithSpan injects trace_id and span_id when a span is active.
//
//nolint:paralleltest // modifies global OTel tracer provider; cannot run concurrently
func TestNewSlogHandler_WithSpan(t *testing.T) {
	// Not parallel: installs a global tracer provider.
	original := otel.GetTracerProvider() // capture before overwriting
	tp := sdktrace.NewTracerProvider()
	otel.SetTracerProvider(tp)
	t.Cleanup(func() {
		_ = tp.Shutdown(context.Background())
		otel.SetTracerProvider(original) // restore original
	})

	var buf bytes.Buffer
	inner := slog.NewTextHandler(&buf, nil)
	h := NewSlogHandler(inner)

	tracer := tp.Tracer("test")
	ctx, span := tracer.Start(context.Background(), "test-span")
	defer span.End()

	logger := slog.New(h)
	logger.InfoContext(ctx, "tracing message")

	out := buf.String()
	if !strings.Contains(out, "trace_id") {
		t.Errorf("expected trace_id in output with active span, got: %s", out)
	}
	if !strings.Contains(out, "span_id") {
		t.Errorf("expected span_id in output with active span, got: %s", out)
	}
}

// TestNewTintedHandler returns a non-nil, functional handler.
func TestNewTintedHandler(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	h := NewTintedHandler(&buf, slog.LevelDebug)
	if h == nil {
		t.Fatal("NewTintedHandler() returned nil")
	}

	logger := slog.New(h)
	logger.InfoContext(context.Background(), "tint test message")

	if buf.Len() == 0 {
		t.Error("expected non-empty output from tinted handler")
	}
}

// TestOtelSlogHandler_WithAttrs verifies that pre-attached attributes are preserved
// and OTel span IDs are still injected after WithAttrs.
//
//nolint:paralleltest // modifies global OTel tracer provider; cannot run concurrently
func TestOtelSlogHandler_WithAttrs(t *testing.T) {
	// Not parallel: installs a global tracer provider.
	original := otel.GetTracerProvider()
	tp := sdktrace.NewTracerProvider()
	otel.SetTracerProvider(tp)
	t.Cleanup(func() {
		_ = tp.Shutdown(context.Background())
		otel.SetTracerProvider(original)
	})

	var buf bytes.Buffer
	inner := slog.NewTextHandler(&buf, nil)
	h := NewSlogHandler(inner).WithAttrs([]slog.Attr{slog.String("service", "test-svc")})

	tracer := tp.Tracer("test")
	ctx, span := tracer.Start(context.Background(), "attr-span")
	defer span.End()

	slog.New(h).InfoContext(ctx, "with-attrs message")

	out := buf.String()
	if !strings.Contains(out, "service=test-svc") {
		t.Errorf("expected pre-attached attr in output, got: %s", out)
	}
	if !strings.Contains(out, "trace_id") {
		t.Errorf("expected trace_id after WithAttrs, got: %s", out)
	}
}

// TestDispatchTracer_TraceAgentDispatch_Error records agent dispatch errors.
func TestDispatchTracer_TraceAgentDispatch_Error(t *testing.T) {
	t.Parallel()
	p, _ := NewProvider(Config{})
	defer func() { _ = p.Shutdown(context.Background()) }()

	dt := NewDispatchTracer(p)
	wantErr := errors.New("agent failed")
	_, err := dt.TraceAgentDispatch(context.Background(), "session-err", 3, func(_ context.Context) (string, error) {
		return "", wantErr
	})
	if !errors.Is(err, wantErr) {
		t.Errorf("TraceAgentDispatch() error = %v, want %v", err, wantErr)
	}
}

// TestDispatchTracer_TraceGeminiCall_Error records Gemini call errors.
func TestDispatchTracer_TraceGeminiCall_Error(t *testing.T) {
	t.Parallel()
	p, _ := NewProvider(Config{})
	defer func() { _ = p.Shutdown(context.Background()) }()

	dt := NewDispatchTracer(p)
	wantErr := errors.New("gemini failed")
	err := dt.TraceGeminiCall(context.Background(), "session-err", 1, func(_ context.Context) error {
		return wantErr
	})
	if !errors.Is(err, wantErr) {
		t.Errorf("TraceGeminiCall() error = %v, want %v", err, wantErr)
	}
}

// TestDispatchTracer_RecordTokens delegates to the provider without error.
func TestDispatchTracer_RecordTokens(t *testing.T) {
	t.Parallel()
	p, _ := NewProvider(Config{})
	defer func() { _ = p.Shutdown(context.Background()) }()

	dt := NewDispatchTracer(p)
	// Should not panic (no-op provider has nil counter, nil guard handles it).
	dt.RecordTokens(context.Background(), 50)
}

// TestDispatchTracer_RecordTokens_NilProvider is safe to call on nil provider.
func TestDispatchTracer_RecordTokens_NilProvider(t *testing.T) {
	t.Parallel()
	dt := NewDispatchTracer(nil)
	dt.RecordTokens(context.Background(), 50) // should not panic
}

// TestProvider_RecordConsolidationTriggered does not panic in no-op mode.
func TestProvider_RecordConsolidationTriggered(t *testing.T) {
	t.Parallel()
	p, _ := NewProvider(Config{})
	defer func() { _ = p.Shutdown(context.Background()) }()
	p.RecordConsolidationTriggered(context.Background())
}

// TestProvider_RecordFactsExtracted does not panic in no-op mode.
func TestProvider_RecordFactsExtracted(t *testing.T) {
	t.Parallel()
	p, _ := NewProvider(Config{})
	defer func() { _ = p.Shutdown(context.Background()) }()
	p.RecordFactsExtracted(context.Background(), 5)
}

// TestProvider_RecordFactsIndexed does not panic in no-op mode.
func TestProvider_RecordFactsIndexed(t *testing.T) {
	t.Parallel()
	p, _ := NewProvider(Config{})
	defer func() { _ = p.Shutdown(context.Background()) }()
	p.RecordFactsIndexed(context.Background(), 3)
}

// TestProvider_RecordFactsSkipped does not panic in no-op mode.
func TestProvider_RecordFactsSkipped(t *testing.T) {
	t.Parallel()
	p, _ := NewProvider(Config{})
	defer func() { _ = p.Shutdown(context.Background()) }()
	p.RecordFactsSkipped(context.Background(), 2)
}

// TestNewProvider_OTLPPath exercises the full OTLP initialization path.
// gRPC dials lazily so this returns in <5ms even with an unavailable endpoint.
//
//nolint:paralleltest // modifies global OTel tracer/meter providers; cannot run concurrently
func TestNewProvider_OTLPPath(t *testing.T) {
	origTP := otel.GetTracerProvider()
	origMP := otel.GetMeterProvider()
	t.Cleanup(func() {
		otel.SetTracerProvider(origTP)
		otel.SetMeterProvider(origMP)
	})

	p, err := NewProvider(Config{
		OTLPEndpoint:   "localhost:9999", // unreachable; gRPC connects lazily
		ServiceName:    "test-svc",
		ServiceVersion: "0.0.1",
		SamplingRate:   0.5,
	})
	if err != nil {
		t.Skipf("NewProvider OTLP path failed (integration env required): %v", err)
	}
	if p == nil {
		t.Fatal("expected non-nil provider")
	}
	if p.Tracer() == nil {
		t.Error("Tracer() should be non-nil after OTLP init")
	}
	// Shutdown with a short timeout — export will fail but that is expected.
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	_ = p.Shutdown(ctx) // error expected (unreachable endpoint); ignore
}

// TestProvider_Shutdown_WithProviders exercises Shutdown when providers are non-nil.
func TestProvider_Shutdown_WithProviders(t *testing.T) {
	t.Parallel()
	tp := sdktrace.NewTracerProvider()
	mp := sdkmetric.NewMeterProvider()
	p := &Provider{
		tracerProvider: tp,
		meterProvider:  mp,
		tracer:         tp.Tracer("test"),
		meter:          mp.Meter("test"),
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := p.Shutdown(ctx); err != nil {
		t.Errorf("Shutdown() error = %v", err)
	}
}

// TestProvider_RecordMetrics_NonNil exercises record methods when counters are non-nil.
func TestProvider_RecordMetrics_NonNil(t *testing.T) {
	t.Parallel()
	mp := sdkmetric.NewMeterProvider()
	meter := mp.Meter("test")
	counter, _ := meter.Int64Counter("test_counter")
	histogram, _ := meter.Float64Histogram("test_histogram")
	p := &Provider{
		tracer:                  otel.Tracer("test"),
		meter:                   meter,
		tokenCounter:            counter,
		toolHistogram:           histogram,
		consolidationsTriggered: counter,
		factsExtracted:          counter,
		factsIndexed:            counter,
		factsSkipped:            counter,
	}
	ctx := context.Background()
	p.RecordTokens(ctx, 10)
	p.RecordToolDuration(ctx, 5*time.Millisecond)
	p.RecordConsolidationTriggered(ctx)
	p.RecordFactsExtracted(ctx, 3)
	p.RecordFactsIndexed(ctx, 2)
	p.RecordFactsSkipped(ctx, 1)
	_ = mp.Shutdown(ctx)
}

// TestOtelSlogHandler_WithGroup verifies that a group prefix is preserved
// and OTel span IDs are still injected after WithGroup.
//
//nolint:paralleltest // modifies global OTel tracer provider; cannot run concurrently
func TestOtelSlogHandler_WithGroup(t *testing.T) {
	// Not parallel: installs a global tracer provider.
	original := otel.GetTracerProvider()
	tp := sdktrace.NewTracerProvider()
	otel.SetTracerProvider(tp)
	t.Cleanup(func() {
		_ = tp.Shutdown(context.Background())
		otel.SetTracerProvider(original)
	})

	var buf bytes.Buffer
	inner := slog.NewTextHandler(&buf, nil)
	h := NewSlogHandler(inner).WithGroup("req")

	tracer := tp.Tracer("test")
	ctx, span := tracer.Start(context.Background(), "group-span")
	defer span.End()

	slog.New(h).InfoContext(ctx, "with-group message", slog.String("id", "42"))

	out := buf.String()
	// Group prefix appears as "req.id=42" in text handler output
	if !strings.Contains(out, "req.id=42") {
		t.Errorf("expected grouped attr in output, got: %s", out)
	}
	if !strings.Contains(out, "trace_id") {
		t.Errorf("expected trace_id after WithGroup, got: %s", out)
	}
}
