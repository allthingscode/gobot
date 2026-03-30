package observability

import (
	"context"
	"time"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
)

// DispatchTracer wraps dispatch operations with tracing.
type DispatchTracer struct {
	provider *Provider
}

// NewDispatchTracer creates a new dispatch tracer.
func NewDispatchTracer(provider *Provider) *DispatchTracer {
	return &DispatchTracer{provider: provider}
}

// TraceBotDispatch traces a Telegram bot dispatch operation.
func (d *DispatchTracer) TraceBotDispatch(ctx context.Context, sessionKey string, fn func(context.Context) error) error {
	if d.provider == nil {
		return fn(ctx)
	}
	ctx, span := d.provider.StartSpan(ctx, "telegram.dispatch",
		attribute.String("session.key", sessionKey),
	)
	defer span.End()

	err := fn(ctx)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
	}
	return err
}

// TraceAgentDispatch traces an agent session dispatch operation.
func (d *DispatchTracer) TraceAgentDispatch(ctx context.Context, sessionKey string, messageCount int, fn func(context.Context) (string, error)) (string, error) {
	if d.provider == nil {
		return fn(ctx)
	}
	ctx, span := d.provider.StartSpan(ctx, "agent.dispatch",
		attribute.String("session.key", sessionKey),
		attribute.Int("message.count", messageCount),
	)
	defer span.End()

	response, err := fn(ctx)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
	} else {
		span.SetAttributes(attribute.Int("response.length", len(response)))
	}
	return response, err
}

// TraceGeminiCall traces a Gemini API call.
func (d *DispatchTracer) TraceGeminiCall(ctx context.Context, sessionKey string, iter int, fn func(context.Context) error) error {
	if d.provider == nil {
		return fn(ctx)
	}
	ctx, span := d.provider.StartSpan(ctx, "gemini.generate",
		attribute.String("session.key", sessionKey),
		attribute.Int("iteration", iter),
	)
	defer span.End()

	start := time.Now()
	err := fn(ctx)
	duration := time.Since(start)

	span.SetAttributes(attribute.Float64("duration_ms", float64(duration.Milliseconds())))
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
	}
	return err
}

// TraceToolExecution traces a tool execution with duration metrics.
func (d *DispatchTracer) TraceToolExecution(ctx context.Context, sessionKey, toolName string, fn func(context.Context) (string, error)) (string, error) {
	if d.provider == nil {
		return fn(ctx)
	}
	ctx, span := d.provider.StartSpan(ctx, "tool.execute",
		attribute.String("session.key", sessionKey),
		attribute.String("tool.name", toolName),
	)
	defer span.End()

	start := time.Now()
	result, err := fn(ctx)
	duration := time.Since(start)

	// Record metric
	d.provider.RecordToolDuration(ctx, duration)

	span.SetAttributes(
		attribute.Float64("duration_ms", float64(duration.Milliseconds())),
		attribute.Int("result.length", len(result)),
	)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
	}
	return result, err
}
