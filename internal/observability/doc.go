// Package observability provides OpenTelemetry tracing and metrics for the Gobot agent chain.
//
// The package exports distributed traces and metrics to an OTLP-compatible collector
// (e.g., Jaeger for traces, Prometheus for metrics via OpenTelemetry Collector).
//
// # Usage
//
// Initialize the provider at application startup:
//
//	p, err := observability.NewProvider(observability.Config{
//	    ServiceName:    "gobot",
//	    ServiceVersion: "1.0.0",
//	    OTLPEndpoint:   "localhost:4317",
//	    SamplingRate:   1.0,
//	})
//	if err != nil {
//	    log.Fatal(err)
//	}
//	defer p.Shutdown(context.Background())
//
// Use the dispatch tracer to instrument operations:
//
//	dt := observability.NewDispatchTracer(p)
//	response, err := dt.TraceAgentDispatch(ctx, sessionKey, msgCount, func(ctx context.Context) (string, error) {
//	    return agent.Dispatch(ctx, sessionKey, message)
//	})
//
// # Metrics
//
// The following metrics are exported:
//
//   - agent_tokens_consumed_total: Total tokens consumed by Gemini API calls
//   - tool_execution_duration_seconds: Histogram of tool execution durations
//
// # Traces
//
// The following spans are created:
//
//   - telegram.dispatch: Telegram message dispatch
//   - agent.dispatch: Agent session dispatch
//   - gemini.generate: Gemini API generation call
//   - tool.execute: Tool execution
//
package observability
