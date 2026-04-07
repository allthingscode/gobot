// Package observability provides OpenTelemetry tracing and metrics for the agent chain.
package observability

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"time"

	"github.com/lmittmann/tint"
	slogcommon "github.com/samber/slog-otel"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
)

// otelSlogHandler wraps a slog.Handler and injects OTel trace_id/span_id
// from the active span into each log record that carries a context.
type otelSlogHandler struct {
	inner    slog.Handler
	attrFunc func(ctx context.Context) []slog.Attr
}

// NewSlogHandler wraps base with an OpenTelemetry-aware handler that injects
// trace_id and span_id attributes when a span is active in the log context.
func NewSlogHandler(base slog.Handler) slog.Handler {
	return &otelSlogHandler{
		inner:    base,
		attrFunc: slogcommon.ExtractOtelAttrFromContext(nil, "trace_id", "span_id"),
	}
}

func (h *otelSlogHandler) Enabled(ctx context.Context, level slog.Level) bool {
	return h.inner.Enabled(ctx, level)
}

func (h *otelSlogHandler) Handle(ctx context.Context, r slog.Record) error {
	attrs := h.attrFunc(ctx)
	if len(attrs) > 0 {
		r = r.Clone()
		r.AddAttrs(attrs...)
	}
	return h.inner.Handle(ctx, r)
}

func (h *otelSlogHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return &otelSlogHandler{inner: h.inner.WithAttrs(attrs), attrFunc: h.attrFunc}
}

func (h *otelSlogHandler) WithGroup(name string) slog.Handler {
	return &otelSlogHandler{inner: h.inner.WithGroup(name), attrFunc: h.attrFunc}
}

// NewTintedHandler returns a colorized slog.Handler for development console output.
// level controls the minimum log level emitted.
func NewTintedHandler(w io.Writer, level slog.Level) slog.Handler {
	return tint.NewHandler(w, &tint.Options{
		Level:   level,
		NoColor: false,
	})
}

// Config holds observability configuration.
type Config struct {
	// ServiceName is the name of this service in traces/metrics.
	ServiceName string
	// ServiceVersion is the version of this service.
	ServiceVersion string
	// OTLPEndpoint is the OTLP collector endpoint (e.g., "localhost:4317").
	// If empty, telemetry is disabled (no-op).
	OTLPEndpoint string
	// SamplingRate is the trace sampling rate (0.0 to 1.0). Default 1.0.
	SamplingRate float64
}

// Provider manages OpenTelemetry tracer and meter providers.
type Provider struct {
	tracerProvider *sdktrace.TracerProvider
	meterProvider  *sdkmetric.MeterProvider
	tracer         trace.Tracer
	meter          metric.Meter

	// Metrics
	tokenCounter           metric.Int64Counter
	toolHistogram          metric.Float64Histogram
	consolidationsTriggered metric.Int64Counter
	factsExtracted         metric.Int64Counter
	factsIndexed           metric.Int64Counter
	factsSkipped           metric.Int64Counter
}

// NewProvider initializes OpenTelemetry with OTLP exporters.
// Returns a no-op provider if cfg.OTLPEndpoint is empty.
func NewProvider(cfg Config) (*Provider, error) {
	if cfg.ServiceName == "" {
		cfg.ServiceName = "gobot"
	}
	if cfg.ServiceVersion == "" {
		cfg.ServiceVersion = "0.0.0"
	}
	if cfg.SamplingRate <= 0 {
		cfg.SamplingRate = 1.0
	}

	// No-op provider if no endpoint configured
	if cfg.OTLPEndpoint == "" {
		slog.Info("observability: OTLP endpoint not configured, telemetry disabled")
		return &Provider{
			tracer: otel.Tracer("noop"),
			meter:  otel.Meter("noop"),
		}, nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	res, err := resource.New(ctx,
		resource.WithAttributes(
			attribute.String("service.name", cfg.ServiceName),
			attribute.String("service.version", cfg.ServiceVersion),
		),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create resource: %w", err)
	}

	// Trace exporter
	traceExporter, err := otlptracegrpc.New(ctx,
		otlptracegrpc.WithEndpoint(cfg.OTLPEndpoint),
		otlptracegrpc.WithInsecure(), // Local collector, no TLS needed
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create trace exporter: %w", err)
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithResource(res),
		sdktrace.WithSampler(sdktrace.TraceIDRatioBased(cfg.SamplingRate)),
		sdktrace.WithBatcher(traceExporter),
	)

	// Metric exporter
	metricExporter, err := otlpmetricgrpc.New(ctx,
		otlpmetricgrpc.WithEndpoint(cfg.OTLPEndpoint),
		otlpmetricgrpc.WithInsecure(),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create metric exporter: %w", err)
	}

	mp := sdkmetric.NewMeterProvider(
		sdkmetric.WithResource(res),
		sdkmetric.WithReader(sdkmetric.NewPeriodicReader(metricExporter)),
	)

	// Set global providers
	otel.SetTracerProvider(tp)
	otel.SetMeterProvider(mp)
	otel.SetTextMapPropagator(propagation.TraceContext{})

	tracer := tp.Tracer(cfg.ServiceName)
	meter := mp.Meter(cfg.ServiceName)

	// Create metrics
	tokenCounter, err := meter.Int64Counter(
		"agent_tokens_consumed_total",
		metric.WithDescription("Total number of tokens consumed by Gemini API calls"),
		metric.WithUnit("1"),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create token counter: %w", err)
	}

	toolHistogram, err := meter.Float64Histogram(
		"tool_execution_duration_seconds",
		metric.WithDescription("Duration of tool execution in seconds"),
		metric.WithUnit("s"),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create tool duration histogram: %w", err)
	}

	consolidationsTriggered, err := meter.Int64Counter(
		"consolidations_triggered_total",
		metric.WithDescription("Total number of memory consolidation operations triggered"),
		metric.WithUnit("1"),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create consolidations counter: %w", err)
	}

	factsExtracted, err := meter.Int64Counter(
		"facts_extracted_total",
		metric.WithDescription("Total number of facts extracted by consolidator"),
		metric.WithUnit("1"),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create facts extracted counter: %w", err)
	}

	factsIndexed, err := meter.Int64Counter(
		"facts_indexed_total",
		metric.WithDescription("Total number of facts indexed to long-term memory"),
		metric.WithUnit("1"),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create facts indexed counter: %w", err)
	}

	factsSkipped, err := meter.Int64Counter(
		"facts_skipped_total",
		metric.WithDescription("Total number of facts skipped during consolidation (duplicates, etc.)"),
		metric.WithUnit("1"),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create facts skipped counter: %w", err)
	}

	return &Provider{
		tracerProvider:          tp,
		meterProvider:           mp,
		tracer:                  tracer,
		meter:                   meter,
		tokenCounter:            tokenCounter,
		toolHistogram:           toolHistogram,
		consolidationsTriggered: consolidationsTriggered,
		factsExtracted:          factsExtracted,
		factsIndexed:            factsIndexed,
		factsSkipped:            factsSkipped,
	}, nil
}

// Tracer returns the OpenTelemetry tracer.
func (p *Provider) Tracer() trace.Tracer {
	return p.tracer
}

// StartSpan starts a new span with the given name and attributes.
// Returns the context with the span and the span itself.
func (p *Provider) StartSpan(ctx context.Context, name string, attrs ...attribute.KeyValue) (context.Context, trace.Span) {
	return p.tracer.Start(ctx, name, trace.WithAttributes(attrs...))
}

// RecordTokens records token consumption.
func (p *Provider) RecordTokens(ctx context.Context, count int64) {
	if p.tokenCounter == nil {
		return
	}
	p.tokenCounter.Add(ctx, count)
}

// RecordToolDuration records tool execution duration.
func (p *Provider) RecordToolDuration(ctx context.Context, duration time.Duration) {
	if p.toolHistogram == nil {
		return
	}
	p.toolHistogram.Record(ctx, duration.Seconds())
}

// RecordConsolidationTriggered records a memory consolidation trigger event.
func (p *Provider) RecordConsolidationTriggered(ctx context.Context) {
	if p.consolidationsTriggered == nil {
		return
	}
	p.consolidationsTriggered.Add(ctx, 1)
}

// RecordFactsExtracted records the number of facts extracted during consolidation.
func (p *Provider) RecordFactsExtracted(ctx context.Context, count int64) {
	if p.factsExtracted == nil {
		return
	}
	p.factsExtracted.Add(ctx, count)
}

// RecordFactsIndexed records the number of facts successfully indexed to memory.
func (p *Provider) RecordFactsIndexed(ctx context.Context, count int64) {
	if p.factsIndexed == nil {
		return
	}
	p.factsIndexed.Add(ctx, count)
}

// RecordFactsSkipped records the number of facts skipped during consolidation.
func (p *Provider) RecordFactsSkipped(ctx context.Context, count int64) {
	if p.factsSkipped == nil {
		return
	}
	p.factsSkipped.Add(ctx, count)
}

// Shutdown gracefully shuts down the providers.
func (p *Provider) Shutdown(ctx context.Context) error {
	if p.tracerProvider == nil && p.meterProvider == nil {
		return nil
	}

	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	if p.tracerProvider != nil {
		if err := p.tracerProvider.Shutdown(ctx); err != nil {
			slog.Warn("observability: failed to shutdown tracer provider", "err", err)
		}
	}
	if p.meterProvider != nil {
		if err := p.meterProvider.Shutdown(ctx); err != nil {
			slog.Warn("observability: failed to shutdown meter provider", "err", err)
		}
	}
	return nil
}
