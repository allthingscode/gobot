package app

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/dashboard"
	"github.com/allthingscode/gobot/internal/doctor"
	"github.com/allthingscode/gobot/internal/memory/consolidator"
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
	startupStart := time.Now()

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

	logWriter := SetupLogging(cfg, hub)
	defer func() { _ = logWriter.Close() }()
	LogBootMemory(slog.Default())
	runPreFlightDiagnostics(cfg)

	if err := config.ReportValidation(cfg); err != nil {
		return fmt.Errorf("config validation: %w", err)
	}

	otelProvider, _ := SetupOTel(ctx, cfg)
	if otelProvider != nil {
		defer shutdownOTel(otelProvider)
	}

	latencyRecorder := observability.NewLatencyRecorder(observability.DefaultLatencyCapacity)
	tracer := observability.NewDispatchTracerWithLatency(otelProvider, latencyRecorder, func(snapshot observability.LatencySnapshot) error {
		return observability.WriteLatencySnapshot(cfg.StorageRoot(), snapshot)
	})
	tmgr := reporter.NewTemplateManagerWithCSS(cfg.TemplatesPath(), cfg.Runtime.CustomCSSPath)
	stack, cleanup, err := BuildAgentStack(ctx, cfg, tmgr, tracer)
	if err != nil {
		return err
	}
	return runWithStackCleanup(cleanup, func() error {
		return runAgentLoop(ctx, cfg, stack, otelProvider, hub, tracer, tmgr, startupStart)
	})
}

// runWithStackCleanup retains resources if accepted consolidation still owns them.
func runWithStackCleanup(cleanup func(), run func() error) error {
	err := run()
	if errors.Is(err, consolidator.ErrDrainTimeout) {
		slog.Error("run: retaining memory and vector stores; consolidation workers still active", "err", err)
	} else {
		cleanup()
	}
	return err
}

// runOwnedConsolidation installs the join before any later runtime exits.
func runOwnedConsolidation(owned *consolidator.Consolidator, cancel context.CancelFunc, timeout time.Duration, run func() error) (runErr error) {
	defer func() {
		cancel()
		runErr = shutdownConsolidation(owned, runErr, timeout)
	}()
	return run()
}

func shutdownConsolidation(owned *consolidator.Consolidator, runErr error, timeout time.Duration) error {
	if owned == nil {
		return runErr
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	if err := owned.Shutdown(ctx); err != nil {
		return errors.Join(runErr, fmt.Errorf("run agent consolidation shutdown: %w", err))
	}
	return runErr
}

func validateRunPrerequisites(cfg *config.Config) error {
	if cfg.Channels.Telegram.Enabled && cfg.TelegramToken() == "" {
		return fmt.Errorf("TELEGRAM_BOT_TOKEN must be set")
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

func runAgentLoop(ctx context.Context, cfg *config.Config, stack *AgentStack, otelProvider *observability.Provider, hub *dashboard.Hub, tracer *observability.DispatchTracer, tmgr *reporter.TemplateManager, startupStart time.Time) error {
	return runAgentLoopWithTelegram(ctx, cfg, stack, otelProvider, hub, tracer, tmgr, startupStart, NewTgAPI)
}

func runAgentLoopWithTelegram(ctx context.Context, cfg *config.Config, stack *AgentStack, otelProvider *observability.Provider, hub *dashboard.Hub, tracer *observability.DispatchTracer, tmgr *reporter.TemplateManager, startupStart time.Time, newTelegram func(string, []string, *config.Config) (*TgAPI, error)) error {
	api, err := initializeStartupTelegram(cfg, newTelegram)
	if err != nil {
		return err
	}
	return runInitializedAgentLoop(ctx, cfg, stack, otelProvider, hub, tracer, tmgr, startupStart, api)
}

func initializeStartupTelegram(cfg *config.Config, newTelegram func(string, []string, *config.Config) (*TgAPI, error)) (*TgAPI, error) {
	var api *TgAPI
	if cfg.Channels.Telegram.Enabled {
		var err error
		api, err = newTelegram(cfg.TelegramToken(), cfg.TelegramAllowedFrom(), cfg)
		if err != nil || api == nil {
			// Constructor errors may contain credentials, request URLs, or server
			// bodies. Retain only a safe replacement at the startup boundary.
			return nil, fmt.Errorf("run agent: %w", fmt.Errorf("telegram initialization failed; check configured credentials and connectivity"))
		}
	}
	return api, nil
}

func runInitializedAgentLoop(ctx context.Context, cfg *config.Config, stack *AgentStack, otelProvider *observability.Provider, hub *dashboard.Hub, tracer *observability.DispatchTracer, tmgr *reporter.TemplateManager, startupStart time.Time, api *TgAPI) error {
	var wg sync.WaitGroup
	// Derive a cancellable context so a critical subsystem failure can trigger
	// shutdown of the rest. startErr collects the first non-graceful failure from
	// a critical subsystem (the HTTP listeners); it is buffered and written with
	// non-blocking sends so a failing goroutine never blocks startup or draining.
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	startErr := make(chan error, 2)
	readiness := NewReadiness()

	store := runtimeCheckpointStore(cfg.StorageRoot())

	mgr := stack.NewSessionManager(cfg, store, tracer)
	_, hitl, err := SetupHooks(cfg, stack.Runner, mgr, api, store)
	if err != nil {
		return fmt.Errorf("run agent: %w", err)
	}
	InitIdempotency(ctx, cfg, stack.Runner, store, &wg)

	handler := &DispatchHandler{Mgr: mgr, Memory: stack.MemStore, Hitl: hitl}
	owned := SetupConsolidator(ctx, cfg, stack, mgr, handler, otelProvider, tracer)
	return runOwnedConsolidation(owned, cancel, 5*time.Second, func() error {

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

		publishStartupReady(ctx, cfg, readiness, startupStart, api, os.Stdout, 2*time.Second)

		StartCron(ctx, cfg, stack, b, tmgr, tracer, &wg)
		StartHeartbeat(ctx, cfg, cfg.TelegramToken(), alertSenderFromAPI(api), &wg)

		return waitForShutdown(ctx, cancel, &wg, startErr, readiness)
	})
}

// runtimeCheckpointStore preserves optional checkpoint storage during startup.
func runtimeCheckpointStore(storageRoot string) agent.CheckpointStore {
	checkpoints, err := agentctx.GetCheckpointManager(storageRoot)
	if err != nil {
		slog.Warn("run: checkpoint store unavailable", "err", err)
		return nil
	}
	return checkpoints
}

// awaitReadyForBanner reports whether startup success can be published.
func awaitReadyForBanner(ctx context.Context, cfg *config.Config, readiness *Readiness) bool {
	return awaitReadyForBannerWithTimeout(ctx, cfg, readiness, 2*time.Second)
}

func awaitReadyForBannerWithTimeout(ctx context.Context, cfg *config.Config, readiness *Readiness, timeout time.Duration) bool {
	if !cfg.Gateway.Enabled {
		return true
	}
	if readiness == nil || ctx.Err() != nil {
		return false
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-readiness.Ready():
		return ctx.Err() == nil && readiness.IsReady()
	case <-ctx.Done():
		return false
	case <-timer.C:
		return false
	}
}

// publishStartupReady keeps the banner, metric and marker behind one readiness gate.
// Subsystem errors remain buffered for waitForShutdown to classify and propagate.
func publishStartupReady(ctx context.Context, cfg *config.Config, readiness *Readiness, startupStart time.Time, api *TgAPI, w io.Writer, timeout time.Duration) {
	if !awaitReadyForBannerWithTimeout(ctx, cfg, readiness, timeout) {
		return
	}
	readyAt := time.Now()
	if cfg.Gateway.Enabled {
		if readinessAt, ok := readiness.ReadyAt(); ok {
			readyAt = readinessAt
		}
	}
	recordStartupReady(cfg, startupStart, readyAt)
	printStartupBannerTo(w, cfg, api)
}

const startupDisabled = "disabled"

func printStartupBannerTo(w io.Writer, cfg *config.Config, api *TgAPI) {
	username := startupDisabled
	if cfg.Channels.Telegram.Enabled && api != nil {
		username = "@" + api.Username()
	}

	dashAddr := startupDisabled
	if cfg.Gateway.Enabled && cfg.Gateway.DashboardEnabled {
		host := strings.Trim(cfg.Gateway.Host, "[]")
		dashAddr = fmt.Sprintf("http://%s/dash/", net.JoinHostPort(host, strconv.Itoa(cfg.Gateway.Port)))
	}

	fmt.Fprintf(w, "gobot ready\n")
	fmt.Fprintf(w, "  Telegram:  %s\n", username)
	fmt.Fprintf(w, "  Provider:  %s (%s)\n", cfg.DefaultProvider(), cfg.DefaultModel())
	fmt.Fprintf(w, "  Dashboard: %s\n", dashAddr)
	fmt.Fprintf(w, "  Storage:   %s\n", cfg.StorageRoot())
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
	return waitForShutdownWithSignals(ctx, cancel, wg, startErr, readiness, signal.Notify, signal.Stop)
}

// waitForShutdownWithSignals owns the subscription; callbacks are per-call so
// tests can exercise its lifetime without delivering process-wide signals.
func waitForShutdownWithSignals(ctx context.Context, cancel context.CancelFunc, wg *sync.WaitGroup, startErr <-chan error, readiness *Readiness, notify func(chan<- os.Signal, ...os.Signal), stop func(chan<- os.Signal)) error {
	sigChan := make(chan os.Signal, 1)
	notify(sigChan, os.Interrupt, syscall.SIGTERM)
	defer stop(sigChan)

	return waitForShutdownTrigger(ctx, cancel, wg, startErr, readiness, sigChan, 5*time.Second)
}

func waitForShutdownTrigger(ctx context.Context, cancel context.CancelFunc, wg *sync.WaitGroup, startErr <-chan error, readiness *Readiness, sigChan <-chan os.Signal, drainTimeout time.Duration) error {
	var subsystemErr error
	select {
	case sig := <-sigChan:
		slog.Info("gobot: received signal, shutting down", "signal", sig)
	case <-ctx.Done():
		slog.Info("gobot: context canceled, shutting down")
	case err := <-startErr:
		slog.Error("gobot: critical subsystem failed to start, shutting down", "err", err)
		subsystemErr = err
	}

	// Flip readiness off as soon as shutdown begins, before draining, so /ready
	// reports 503 during the drain window while /health (liveness) stays 200.
	if readiness != nil {
		readiness.SetNotReady()
	}

	// Let cancellation-dependent workers begin cleanup within the drain budget.
	cancel()
	DrainGoroutines(wg, drainTimeout)
	return subsystemErr
}
