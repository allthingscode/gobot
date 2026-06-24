package app

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/dashboard"
	"github.com/allthingscode/gobot/internal/memory/consolidator"
	"github.com/allthingscode/gobot/internal/observability"
	"gopkg.in/natefinch/lumberjack.v2"
)

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
	if !ok || mgr == nil {
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

// ReconcileAuthorizedFromAllowFrom promotes every Telegram chat ID in
// channels.telegram.allowFrom (the trusted network whitelist) into the
// authorization database on boot, so a single-user happy path no longer requires a
// manual `gobot authorize` step. It is idempotent: already-authorized IDs are left
// untouched and only newly authorized IDs are logged. A nil or non-pairing store is
// a no-op. Returns the number of IDs newly authorized.
func ReconcileAuthorizedFromAllowFrom(cfg *config.Config, store agent.CheckpointStore) int {
	if cfg == nil || store == nil {
		return 0
	}
	mgr, ok := store.(*agentctx.CheckpointManager)
	if !ok {
		return 0
	}
	pairingStore, err := agentctx.NewPairingStore(mgr.DB())
	if err != nil {
		slog.Warn("run: allowFrom reconcile skipped, pairing store unavailable", "err", err)
		return 0
	}

	reconciled := 0
	for _, raw := range cfg.TelegramAllowedFrom() {
		chatID, perr := strconv.ParseInt(raw, 10, 64)
		if perr != nil {
			continue // non-numeric entries are ignored, mirroring NewTgAPI
		}
		authorized, aerr := pairingStore.IsAuthorized(chatID)
		if aerr != nil {
			slog.Warn("run: allowFrom reconcile: authorization check failed", "chat_id", chatID, "err", aerr)
			continue
		}
		if authorized {
			continue
		}
		if err := pairingStore.AuthorizeByChatID(chatID, "allowFrom-reconcile"); err != nil {
			slog.Warn("run: allowFrom reconcile: authorize failed", "chat_id", chatID, "err", err)
			continue
		}
		reconciled++
		slog.Info("run: authorized allowFrom chat ID from whitelist", "chat_id", chatID)
	}
	return reconciled
}
