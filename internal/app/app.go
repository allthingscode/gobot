package app

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/dashboard"
	"github.com/allthingscode/gobot/internal/doctor"
	"github.com/allthingscode/gobot/internal/observability"
	"github.com/allthingscode/gobot/internal/reporter"
)

// Version is the build version surfaced on the dashboard home page. It defaults
// to "dev" and is overridden at build time via -ldflags (F-139).
//
//nolint:gochecknoglobals // build-time injection point, treated as immutable at runtime
var Version = "dev"

// RunAgent is the high-level entry point for the strategic agent.
func RunAgent(ctx context.Context, cfg *config.Config) error {
	// F-133: Record project root from where we were started.
	if wd, err := os.Getwd(); err == nil {
		cfg.SetProjectRoot(wd)
	}

	if err := validateRunPrerequisites(cfg); err != nil {
		return err
	}

	var hub *dashboard.Hub
	if cfg.Gateway.WebAddr != "" {
		hub = dashboard.NewHub(1000)
		defer hub.Close()
	}

	SetupLogging(cfg, hub)
	LogBootMemory(slog.Default())
	runPreFlightDiagnostics(cfg)

	if err := config.ReportValidation(cfg); err != nil {
		return fmt.Errorf("config validation: %w", err)
	}

	otelProvider, _ := SetupOTel(ctx, cfg)
	if otelProvider != nil {
		defer shutdownOTel(otelProvider)
	}

	tracer := observability.NewDispatchTracer(otelProvider)
	tmgr := reporter.NewTemplateManagerWithCSS(cfg.TemplatesPath(), cfg.Runtime.CustomCSSPath)
	stack, cleanup, err := BuildAgentStack(ctx, cfg, tmgr, tracer)
	if err != nil {
		return err
	}
	defer cleanup()

	return runAgentLoop(ctx, cfg, stack, otelProvider, hub, tracer, tmgr)
}

func validateRunPrerequisites(cfg *config.Config) error {
	if cfg.Channels.Telegram.Enabled && cfg.TelegramToken() == "" {
		return fmt.Errorf("TELEGRAM_APITOKEN must be set")
	}
	return nil
}

func runPreFlightDiagnostics(cfg *config.Config) {
	if err := doctor.Run(cfg, nil); err != nil {
		slog.Warn("pre-flight diagnostics found issues", "err", err)
	}
}

func shutdownOTel(p *observability.Provider) {
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := p.Shutdown(shutdownCtx); err != nil {
		slog.Warn("gobot: telemetry shutdown failed", "err", err)
	}
}

func runAgentLoop(ctx context.Context, cfg *config.Config, stack *AgentStack, otelProvider *observability.Provider, hub *dashboard.Hub, tracer *observability.DispatchTracer, tmgr *reporter.TemplateManager) error {
	var wg sync.WaitGroup
	// Derive a cancellable context so a critical subsystem failure can trigger
	// shutdown of the rest. startErr collects the first non-graceful failure from
	// a critical subsystem (the HTTP listeners); it is buffered and written with
	// non-blocking sends so a failing goroutine never blocks startup or draining.
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	startErr := make(chan error, 2)
	readiness := NewReadiness()

	checkpoints, err := agentctx.GetCheckpointManager(cfg.StorageRoot())
	var store agent.CheckpointStore
	if err != nil {
		slog.Warn("run: checkpoint store unavailable", "err", err)
	} else if checkpoints != nil {
		store = checkpoints
	}
	InitIdempotency(ctx, cfg, stack.Runner, store, &wg)

	mgr := stack.NewSessionManager(cfg, store, tracer)
	api, _ := NewTgAPI(cfg.TelegramToken(), cfg.TelegramAllowedFrom(), cfg)
	_, hitl := SetupHooks(cfg, stack.Runner, mgr, api, store)

	handler := &DispatchHandler{Mgr: mgr, Memory: stack.MemStore, Hitl: hitl}
	SetupConsolidator(cfg, stack, mgr, handler, otelProvider, tracer)

	gateHandler := SetupGateHandler(store, handler)
	ReconcileAuthorizedFromAllowFrom(cfg, store)
	if cfg.Gateway.Enabled {
		StartGateway(ctx, cfg, store, stack.MemStore, gateHandler, hub, &wg, startErr, readiness)
	}

	if cfg.Gateway.WebAddr != "" && hub != nil {
		StartDashboard(ctx, cfg.Gateway.WebAddr, cfg.Gateway.AuthToken, hub, &wg, startErr)
	}

	var b *bot.Bot
	if cfg.Channels.Telegram.Enabled {
		if api != nil {
			b = StartTelegramBot(ctx, api, gateHandler, tracer, &wg)
		}
	}

	awaitReadyForBanner(ctx, cfg, readiness)
	printStartupBanner(cfg, api)

	StartCron(ctx, cfg, stack, b, tmgr, tracer, &wg)
	StartHeartbeat(ctx, cfg, cfg.TelegramToken(), alertSenderFromAPI(api), &wg)

	return waitForShutdown(ctx, cancel, &wg, startErr, readiness)
}

// awaitReadyForBanner blocks until the gateway listener reports bound, the context
// is cancelled, or a short timeout elapses, so the "gobot ready" banner does not
// print ahead of the bound listener. No-op when the gateway is disabled. On a bind
// failure (no ready signal) it returns after the timeout; waitForShutdown then
// surfaces the error via startErr.
func awaitReadyForBanner(ctx context.Context, cfg *config.Config, readiness *Readiness) {
	if !cfg.Gateway.Enabled || readiness == nil {
		return
	}
	const bannerBindWait = 2 * time.Second
	select {
	case <-readiness.Ready():
	case <-ctx.Done():
	case <-time.After(bannerBindWait):
	}
}

func printStartupBanner(cfg *config.Config, api *TgAPI) {
	username := "disabled"
	if cfg.Channels.Telegram.Enabled && api != nil {
		username = "@" + api.Username()
	}

	dashAddr := "disabled"
	if cfg.Gateway.WebAddr != "" {
		dashAddr = fmt.Sprintf("http://%s/dash/", cfg.Gateway.WebAddr)
	}

	fmt.Fprintf(os.Stdout, "gobot ready\n")
	fmt.Fprintf(os.Stdout, "  Telegram:  %s\n", username)
	fmt.Fprintf(os.Stdout, "  Provider:  %s (%s)\n", cfg.DefaultProvider(), cfg.DefaultModel())
	fmt.Fprintf(os.Stdout, "  Dashboard: %s\n", dashAddr)
	fmt.Fprintf(os.Stdout, "  Storage:   %s\n", cfg.StorageRoot())
}

// reportStartupFailure forwards a non-graceful subsystem failure to startErr so
// runAgentLoop can fail fast. A graceful shutdown (context cancelled) is not a
// failure and is dropped. The send is non-blocking (buffered channel + default)
// so a failing goroutine never blocks; a nil channel is tolerated for callers
// that do not monitor startup (e.g. tests).
func reportStartupFailure(ctx context.Context, startErr chan<- error, subsystem string, err error) {
	if ctx.Err() != nil {
		return
	}
	select {
	case startErr <- fmt.Errorf("%s: %w", subsystem, err):
	default:
	}
}

// waitForShutdown blocks until a shutdown signal, context cancellation, or a
// critical subsystem startup failure. It returns a non-nil error only in the
// last case, so the process exits non-zero when a subsystem fails to start;
// signal/context shutdown returns nil (graceful, exit 0).
func waitForShutdown(ctx context.Context, cancel context.CancelFunc, wg *sync.WaitGroup, startErr <-chan error, readiness *Readiness) error {
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)

	var subsystemErr error
	select {
	case sig := <-sigChan:
		slog.Info("gobot: received signal, shutting down", "signal", sig)
	case <-ctx.Done():
		slog.Info("gobot: context canceled, shutting down")
	case err := <-startErr:
		slog.Error("gobot: critical subsystem failed to start, shutting down", "err", err)
		subsystemErr = err
		cancel()
	}

	// Flip readiness off as soon as shutdown begins, before draining, so /ready
	// reports 503 during the drain window while /health (liveness) stays 200.
	if readiness != nil {
		readiness.SetNotReady()
	}

	const drainTimeout = 5 * time.Second
	DrainGoroutines(wg, drainTimeout)
	return subsystemErr
}
