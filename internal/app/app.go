package app

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/dashboard"
	"github.com/allthingscode/gobot/internal/doctor"
	"github.com/allthingscode/gobot/internal/gateway"
	"github.com/allthingscode/gobot/internal/gateway/dash"
	"github.com/allthingscode/gobot/internal/memory"
	"github.com/allthingscode/gobot/internal/memory/consolidator"
	"github.com/allthingscode/gobot/internal/observability"
	"gopkg.in/natefinch/lumberjack.v2"
)

// RunAgent is the high-level entry point for the strategic agent.
func RunAgent(ctx context.Context, cfg *config.Config) error {
	if err := validateRunPrerequisites(cfg); err != nil {
		return err
	}

	var hub *dashboard.Hub
	if cfg.Gateway.WebAddr != "" {
		hub = dashboard.NewHub(1000)
		defer hub.Close()
	}

	SetupLogging(cfg, hub)
	runPreFlightDiagnostics(cfg)

	if err := config.ReportValidation(cfg); err != nil {
		return fmt.Errorf("config validation: %w", err)
	}

	otelProvider, _ := SetupOTel(ctx, cfg)
	if otelProvider != nil {
		defer shutdownOTel(otelProvider)
	}

	tracer := observability.NewDispatchTracer(otelProvider)
	stack, cleanup, err := BuildAgentStack(ctx, cfg, tracer)
	if err != nil {
		return err
	}
	defer cleanup()

	return runAgentLoop(ctx, cfg, stack, otelProvider, hub, tracer)
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

func runAgentLoop(ctx context.Context, cfg *config.Config, stack *AgentStack, otelProvider *observability.Provider, hub *dashboard.Hub, tracer *observability.DispatchTracer) error {
	var wg sync.WaitGroup
	store, _ := agentctx.GetCheckpointManager(cfg.StorageRoot())
	InitIdempotency(ctx, cfg, stack.Runner, store, &wg)

	mgr := stack.NewSessionManager(cfg, store, tracer)
	api, _ := NewTgAPI(cfg.TelegramToken(), cfg.TelegramAllowedFrom(), cfg)
	_, hitl := SetupHooks(cfg, stack.Runner, mgr, api, store)

	handler := &DispatchHandler{Mgr: mgr, Memory: stack.MemStore, Hitl: hitl}
	SetupConsolidator(cfg, stack, mgr, handler, otelProvider, tracer)

	gateHandler := SetupGateHandler(store, handler)
	if cfg.Gateway.Enabled {
		StartGateway(ctx, cfg, store, stack.MemStore, gateHandler, &wg)
	}

	if cfg.Gateway.WebAddr != "" && hub != nil {
		StartDashboard(ctx, cfg.Gateway.WebAddr, hub, &wg)
	}

	var b *bot.Bot
	if cfg.Channels.Telegram.Enabled {
		b = StartTelegramBot(ctx, api, gateHandler, tracer, &wg)
	}

	StartCron(ctx, cfg, stack, b, tracer, &wg)
	StartHeartbeat(ctx, cfg, cfg.TelegramToken(), &wg)

	waitForShutdown(ctx, &wg)
	return nil
}

// StartDashboard starts the F-111 SSE dashboard server in a separate goroutine.
func StartDashboard(ctx context.Context, addr string, hub *dashboard.Hub, wg *sync.WaitGroup) {
	srv := dashboard.NewServer(hub, addr)
	wg.Add(1)
	go func() {
		defer RecoverWithStack("dashboard")
		defer wg.Done()
		if err := srv.ListenAndServe(ctx); err != nil {
			slog.Error("dashboard: failure", "err", err)
		}
	}()
}

func waitForShutdown(ctx context.Context, wg *sync.WaitGroup) {
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)

	select {
	case sig := <-sigChan:
		slog.Info("gobot: received signal, shutting down", "signal", sig)
	case <-ctx.Done():
		slog.Info("gobot: context canceled, shutting down")
	}

	const drainTimeout = 5 * time.Second
	DrainGoroutines(wg, drainTimeout)
}

// SetupLogging initializes the global structured logger based on configuration.
func SetupLogging(cfg *config.Config, hub *dashboard.Hub) {
	opts := &slog.HandlerOptions{
		Level: cfg.LogLevel(),
	}

	logPath := cfg.LogPath("gobot.log")
	if err := os.MkdirAll(filepath.Dir(logPath), 0o755); err != nil {
		slog.Warn("failed to create logs directory", "path", filepath.Dir(logPath), "err", err)
	}

	rotator := &lumberjack.Logger{
		Filename:   logPath,
		MaxSize:    cfg.Logging.MaxSizeMB,
		MaxBackups: cfg.Logging.MaxBackups,
		MaxAge:     cfg.Logging.MaxAgeDays,
		Compress:   cfg.Logging.Compress,
	}

	// Apply defaults
	if rotator.MaxSize == 0 {
		rotator.MaxSize = 50
	}
	if rotator.MaxBackups == 0 {
		rotator.MaxBackups = 5
	}
	if rotator.MaxAge == 0 {
		rotator.MaxAge = 30
	}
	// Default compress to true unless explicitly false in config (approximate check)
	if !cfg.Logging.Compress && cfg.Logging.MaxSizeMB == 0 {
		rotator.Compress = true
	}

	multi := io.MultiWriter(os.Stderr, rotator)

	var handler slog.Handler = slog.NewTextHandler(multi, opts)
	if cfg.LogFormat() == "json" {
		handler = slog.NewJSONHandler(multi, opts)
	}

	if hub != nil {
		handler = dashboard.NewSlogHandler(hub, handler)
	}

	slog.SetDefault(slog.New(handler))
}

// SetupOTel initializes OpenTelemetry tracing and metrics if enabled in config.
func SetupOTel(ctx context.Context, cfg *config.Config) (*observability.Provider, error) {
	if !cfg.TelemetryEnabled() {
		return nil, nil
	}
	p, err := observability.NewProvider(observability.Config{
		OTLPEndpoint: cfg.OTelEndpoint(),
		ServiceName:  "gobot-strategic",
	})
	if err != nil {
		return nil, fmt.Errorf("new provider: %w", err)
	}
	return p, nil
}

// InitIdempotency configures the idempotency store for side-effecting tools.
func InitIdempotency(ctx context.Context, cfg *config.Config, runner *AgentRunner, store agent.CheckpointStore, wg *sync.WaitGroup) {
	if store == nil {
		return
	}
	// We need to access the underlying DB from the CheckpointStore.
	mgr, ok := store.(*agentctx.CheckpointManager)
	if !ok {
		slog.Warn("run: idempotency store unavailable, store is not CheckpointManager")
		return
	}
	idempStore := agentctx.NewIdempotencyStore(mgr.DB(), cfg.EffectiveIdempotencyTTL())
	runner.SetIdempotencyStore(idempStore)
	slog.Info("run: tool idempotency enabled")

	wg.Add(1)
	go func() {
		defer RecoverWithStack("idempotency-cleanup")
		defer wg.Done()
		RunIdempotencyCleanup(ctx, idempStore, 1*time.Hour)
	}()
}

// SetupHooks initializes and registers lifecycle hooks for the agent and runner.
func SetupHooks(cfg *config.Config, runner *AgentRunner, mgr *agent.SessionManager, api bot.API, store agent.CheckpointStore) (*agent.Hooks, *agent.HITLManager) {
	hooks := &agent.Hooks{}
	hitlStore, _ := store.(agent.HITLStore)
	hitl := agent.NewHITLManager(api, hitlStore, cfg.HighRiskTools())
	hooks.RegisterPostDispatch(agent.NewHandoffHook(cfg.StorageRoot()))

	policyPath := agent.ResolvePolicyFilePath(cfg.PolicyFilePath(), cfg.StorageRoot())
	policy, err := agent.NewFilePolicy(policyPath)
	if err != nil {
		slog.Warn("run: policy file load failed, using allow-all", "err", err)
		policy = agent.AllowAllPolicy{}
	}
	policyHook := agent.NewPolicyHook(policy, hitl)
	hooks.RegisterPreTool(policyHook.PreToolHook)
	hooks.RegisterPreTool(hitl.PreToolHook)

	mgr.SetHooks(hooks)
	runner.SetHooks(hooks)
	return hooks, hitl
}

// SetupConsolidator initializes the memory consolidation engine if a memory store is available.
func SetupConsolidator(cfg *config.Config, stack *AgentStack, mgr *agent.SessionManager, handler *DispatchHandler, otelProvider *observability.Provider, tracer *observability.DispatchTracer) {
	if stack.MemStore == nil {
		return
	}
	h := consolidator.New(stack.Runner, stack.MemStore, stack.VecStore, stack.EmbedProv)
	if tracer != nil {
		h.SetTracer(tracer)
	}
	if cfg.Agents.Defaults.Compaction.Strategy == "memoryFlush" {
		h.SetPrompt(cfg.Agents.Defaults.Compaction.MemoryFlush.Prompt)
		h.SetTTL(cfg.Agents.Defaults.Compaction.MemoryFlush.TTL)
		h.SetGlobalTTL(cfg.Agents.Defaults.Compaction.MemoryFlush.GlobalTTL)
		h.SetGlobalPatterns(cfg.Agents.Defaults.Compaction.MemoryFlush.GlobalNamespacePatterns)
	}
	if otelProvider != nil {
		h.SetObservability(otelProvider)
	}
	handler.Consolidator = h
	mgr.SetConsolidator(h)
	slog.Info("run: memory consolidation enabled")
}

// SetupGateHandler initializes the pairing handler for DM-based authentication.
func SetupGateHandler(store agent.CheckpointStore, handler *DispatchHandler) bot.Handler {
	if store == nil {
		return handler
	}
	mgr, ok := store.(*agentctx.CheckpointManager)
	if !ok {
		return handler
	}
	pairingStore, err := agentctx.NewPairingStore(mgr.DB())
	if err != nil {
		slog.Warn("run: pairing store unavailable, DM pairing disabled", "err", err)
		return handler
	}
	slog.Info("run: DM pairing enabled")
	return bot.NewPairingHandler(pairingStore, handler)
}

// StartGateway starts the HTTP gateway server in a separate goroutine.
func StartGateway(ctx context.Context, cfg *config.Config, store agent.CheckpointStore, memStore *memory.MemoryStore, gateHandler bot.Handler, wg *sync.WaitGroup) {
	mgr, _ := store.(*agentctx.CheckpointManager)
	res := dash.Resources{
		Config:      cfg,
		Checkpoints: mgr,
		Memory:      memStore,
	}
	srv := gateway.NewServer(cfg.Gateway, gateHandler, res)
	wg.Add(1)
	go func() {
		defer RecoverWithStack("gateway")
		defer wg.Done()
		if err := srv.ListenAndServe(ctx); err != nil {
			slog.Error("gateway: failure", "err", err)
		}
	}()
}

// RunIdempotencyCleanup runs periodic background cleanup of expired idempotency keys.
func RunIdempotencyCleanup(ctx context.Context, store *agentctx.IdempotencyStore, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			cleaned, err := store.CleanupExpired(ctx)
			if err != nil {
				slog.Error("run: idempotency cleanup failed", "err", err)
				continue
			}
			if cleaned > 0 {
				slog.Info("run: cleaned up expired idempotency keys", "count", cleaned)
			}
		}
	}
}

// StartTelegramBot initializes and starts the Telegram polling bot.
func StartTelegramBot(ctx context.Context, api bot.API, gateHandler bot.Handler, tracer *observability.DispatchTracer, wg *sync.WaitGroup) *bot.Bot {
	if api == nil {
		slog.Error("gobot: telegram bot initialization failed, API is nil")
		return nil
	}
	b := bot.New(api, gateHandler)
	if tracer != nil {
		b.SetTracer(tracer)
	}
	wg.Add(1)
	go func() {
		defer RecoverWithStack("telegram-bot")
		defer wg.Done()
		if err := b.Run(ctx); err != nil && !errors.Is(err, context.Canceled) {
			slog.Error("telegram: bot runtime failure", "err", err)
		}
	}()
	slog.Info("gobot: telegram bot started")
	return b
}

// StartCron starts the modular cron scheduler in a separate goroutine.
func StartCron(ctx context.Context, cfg *config.Config, stack *AgentStack, b *bot.Bot, tracer *observability.DispatchTracer, wg *sync.WaitGroup) {
	if !cfg.Cron.Enabled {
		return
	}
	mgr := stack.NewSessionManager(cfg, nil, tracer)
	cd := NewCronDispatcher(cfg, mgr, stack, b)
	wg.Add(1)
	go func() {
		defer RecoverWithStack("cron-dispatcher")
		defer wg.Done()
		cd.Run(ctx)
	}()
	slog.Info("gobot: cron dispatcher started")
}

// StartHeartbeat starts the periodic health check runner.
func StartHeartbeat(ctx context.Context, cfg *config.Config, token string, wg *sync.WaitGroup) {
	if !cfg.Heartbeat.Enabled {
		return
	}
	hb := NewHeartbeatRunner(cfg, token)
	wg.Add(1)
	go func() {
		defer RecoverWithStack("heartbeat-runner")
		defer wg.Done()
		hb.Run(ctx)
	}()
	slog.Info("gobot: heartbeat runner started")
}

// DrainGoroutines waits for all registered background tasks to complete or times out.
func DrainGoroutines(wg *sync.WaitGroup, timeout time.Duration) {
	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()
	select {
	case <-done:
		slog.Info("gobot: drain complete, proceeding to shutdown")
	case <-time.After(timeout):
		slog.Warn("gobot: drain timed out forcing exit", "timeout", timeout)
	}
}

// LiveProbes returns health check probes that interact with live APIs.
func LiveProbes() *doctor.Probes {
	return LiveProbesList()
}
