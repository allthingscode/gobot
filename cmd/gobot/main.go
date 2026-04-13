// gobot - Strategic Edition agent runtime (Go)
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"sync"
	"time"

	"github.com/spf13/cobra"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/audit"
	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/cron"
	"github.com/allthingscode/gobot/internal/doctor"
	"github.com/allthingscode/gobot/internal/gateway"
	"github.com/allthingscode/gobot/internal/gateway/dash"
	"github.com/allthingscode/gobot/internal/memory"
	"github.com/allthingscode/gobot/internal/memory/consolidator"
	"github.com/allthingscode/gobot/internal/observability"
)

//nolint:gochecknoglobals // Build-time injection via -ldflags, not mutable at runtime
var (
	version    = "dev"     // overridden at build time via -ldflags
	commitHash = "unknown" // overridden at build time via -ldflags
	buildTime  = "unknown" // overridden at build time via -ldflags
)

func main() {
	root := &cobra.Command{
		Use:   "gobot",
		Short: "Strategic Edition agent runtime",
		Long:  "gobot - the Go-native runtime for gobot Strategic Edition.",
	}
	root.SilenceErrors = true

	root.AddCommand(
		cmdVersion(),
		cmdInit(),
		cmdDoctor(),
		cmdRun(),
		cmdSimulate(),
		cmdRewind(),
		cmdMemory(),
		cmdFactory(),
		cmdLogs(),
		cmdConfig(),
		cmdCheckpoints(),
		cmdResume(),
		cmdAuthorize(),
		cmdReauth(),
		cmdSecrets(),
		cmdEmail(),
		cmdCalendar(),
		cmdTasks(),
		cmdState(),
	)

	if err := root.Execute(); err != nil {
		if !root.SilenceErrors {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		}
		os.Exit(1)
	}
}

func cmdVersion() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print version information",
		Run: func(_ *cobra.Command, _ []string) {
			fmt.Printf("gobot %s (%s) built %s\n", version, commitHash, buildTime)
			fmt.Printf("runtime: %s/%s (%s)\n", runtime.GOOS, runtime.GOARCH, runtime.Version())
		},
	}
}

func cmdInit() *cobra.Command {
	var rootFlag string
	cmd := &cobra.Command{
		Use:   "init",
		Short: "Create gobot workspace directories under the configured storage root",
		RunE: func(_ *cobra.Command, _ []string) error {
			return runInit(rootFlag)
		},
	}
	cmd.Flags().StringVar(&rootFlag, "root", "", "Custom storage root directory")
	return cmd
}

func runInit(rootFlag string) error {
	configPath := config.DefaultConfigPath()
	_, statErr := os.Stat(configPath)
	configMissing := os.IsNotExist(statErr)

	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("config: %w", err)
	}

	// If missing, setup a baseline template
	if configMissing {
		cfg.Agents.Defaults.Model = "gemini-3-flash-preview"
		cfg.Agents.Defaults.MaxTokens = 8192
		cfg.Agents.Defaults.MaxToolIterations = 25
		cfg.Agents.Defaults.MemoryWindow = 50
	}

	// Override root if flag is provided
	if rootFlag != "" {
		cfg.Strategic.StorageRoot = rootFlag
	}

	// Write config if it was missing or if we updated the root
	if configMissing || rootFlag != "" {
		if err := cfg.Save(configPath); err != nil {
			return fmt.Errorf("failed to save config: %w", err)
		}
		if configMissing {
			fmt.Printf("Generated default config at %s\n", configPath)
		}
	}

	dirs := []string{
		cfg.WorkspacePath(""),
		cfg.WorkspacePath("", "jobs"),
		cfg.WorkspacePath("", "journal"),
		cfg.WorkspacePath("", "sessions"),
		cfg.WorkspacePath("", "projects"),
		cfg.WorkspacePath("", "reports"),
		cfg.LogsRoot(),
		cfg.SecretsRoot(),
	}
	for _, d := range dirs {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return fmt.Errorf("failed to create %s: %w", d, err)
		}
		fmt.Printf("  ok  %s\n", d)
	}
	fmt.Printf("init complete. storage root: %s\n", cfg.StorageRoot())
	return nil
}

func cmdDoctor() *cobra.Command {
	var noInteractive bool
	cmd := &cobra.Command{
		Use:   "doctor",
		Short: "Run self-diagnostics and pre-flight checks",
		RunE: func(_ *cobra.Command, _ []string) error {
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config load failed: %w", err)
			}
			var probes *doctor.Probes
			if !noInteractive {
				probes = liveProbes()
			}
			return doctor.Run(cfg, probes)
		},
	}
	cmd.Flags().BoolVar(&noInteractive, "no-interactive", false, "Skip live API probes")
	return cmd
}

func cmdRun() *cobra.Command {
	return &cobra.Command{
		Use:   "run",
		Short: "Start the strategic agent polling loop",
		RunE: func(cmd *cobra.Command, _ []string) error {
			defer recoverFromPanic()

			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config: %w", err)
			}

			setupLogging(cfg)

			if err := doctor.Run(cfg, nil); err != nil {
				slog.Warn("pre-flight diagnostics found issues", "err", err)
			}

			if err := reportConfigValidation(cfg, os.Stderr); err != nil {
				return err
			}

			return runAgent(cmd.Context(), cfg)
		},
	}
}

func recoverFromPanic() {
	if r := recover(); r != nil {
		_, _ = os.Stderr.WriteString("PANIC CAUGHT IN MAIN: " + fmt.Sprint(r) + "\n")
		os.Exit(1)
	}
}

func setupLogging(cfg *config.Config) {
	devMode := cfg.Strategic.Observability.DevMode
	var baseHandler slog.Handler
	var logFileErr error

	if devMode {
		baseHandler = observability.NewTintedHandler(os.Stderr, slog.LevelDebug)
	} else {
		now := time.Now().Format("20060102_150405")
		logName := fmt.Sprintf("gobot_%s.log", now)
		logPath := cfg.LogPath(logName)
		logFile, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		logFileErr = err
		if logFileErr == nil {
			baseHandler = slog.NewTextHandler(io.MultiWriter(os.Stderr, logFile), nil)
			// Note: logFile is not closed here, it stays open for the life of the process.
		} else {
			baseHandler = slog.NewTextHandler(os.Stderr, nil)
		}
	}

	slog.SetDefault(slog.New(observability.NewSlogHandler(audit.NewRedactingHandler(baseHandler))))
	if logFileErr != nil {
		slog.Warn("failed to open log file, logging to stderr only", "err", logFileErr)
	}
}

func runAgent(ctx context.Context, cfg *config.Config) error {
	token := cfg.TelegramToken()
	if token == "" && cfg.Channels.Telegram.Enabled {
		return fmt.Errorf("telegram token not set: add channels.telegram.token to config or set TELEGRAM_BOT_TOKEN env var")
	}

	var wg sync.WaitGroup
	stack, cleanup, err := buildAgentStack(ctx, cfg)
	if err != nil {
		return err
	}
	defer cleanup()

	otelProvider := setupOTel(ctx, cfg)
	if otelProvider != nil {
		defer func() {
			shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if err := otelProvider.Shutdown(shutdownCtx); err != nil {
				slog.Warn("gobot: telemetry shutdown failed", "err", err)
			}
		}()
	}

	tracer := observability.NewDispatchTracer(otelProvider)
	stack.runner.SetTracer(tracer)

	store, _ := agentctx.GetCheckpointManager(cfg.StorageRoot())
	initIdempotency(ctx, cfg, stack.runner, store, &wg)

	mgr := stack.NewSessionManager(cfg, store, tracer)
	_, hitl := setupHooks(cfg, stack.runner, mgr)

	handler := &dispatchHandler{mgr: mgr, memory: stack.memStore, hitl: hitl}
	setupConsolidator(cfg, stack, mgr, handler, otelProvider)

	gateHandler := setupGateHandler(store, handler)

	if cfg.Gateway.Enabled {
		startGateway(ctx, cfg, store, stack.memStore, gateHandler, &wg)
	}

	var b *bot.Bot
	if cfg.Channels.Telegram.Enabled {
		b = startTelegramBot(cfg, token, gateHandler, tracer)
	}

	startCron(ctx, cfg, stack, b, tracer, &wg)
	startHeartbeat(ctx, cfg, token, &wg)

	slog.Info("gobot starting", "model", stack.model)
	if b != nil {
		if err := b.Run(ctx); err != nil {
			return err
		}
	} else {
		slog.Info("gobot running (headless mode)")
		<-ctx.Done()
	}

	slog.Info("gobot: signal received, draining goroutines...")
	drainGoroutines(&wg, 30*time.Second)
	return nil
}

func setupOTel(ctx context.Context, cfg *config.Config) *observability.Provider {
	otelConfig := observability.Config{
		ServiceName:    cfg.Strategic.Observability.ServiceName,
		ServiceVersion: version,
		OTLPEndpoint:   cfg.Strategic.Observability.OTLPEndpoint,
		SamplingRate:   cfg.Strategic.Observability.SamplingRate,
	}
	otelProvider, err := observability.NewProvider(otelConfig)
	if err != nil {
		slog.Warn("run: observability provider failed to initialize", "err", err)
		return nil
	}
	return otelProvider
}

// AgentRunner is the subset of geminiRunner used by setup functions.
type AgentRunner interface {
	SetTracer(t *observability.DispatchTracer)
	SetIdempotencyStore(s *agentctx.IdempotencyStore)
	SetHooks(h *agent.Hooks)
}

func initIdempotency(ctx context.Context, cfg *config.Config, runner AgentRunner, store *agentctx.CheckpointManager, wg *sync.WaitGroup) {
	if store == nil {
		slog.Warn("run: checkpoint store unavailable, running statelessly")
		return
	}

	idempStore := agentctx.NewIdempotencyStore(store.DB(), cfg.EffectiveIdempotencyTTL())
	runner.SetIdempotencyStore(idempStore)

	if cleaned, err := idempStore.CleanupExpired(); err == nil && cleaned > 0 {
		slog.Info("run: cleaned up expired idempotency keys", "count", cleaned)
	}

	wg.Add(1)
	go func() {
		defer wg.Done()
		runIdempotencyCleanup(ctx, idempStore, 6*time.Hour)
	}()
}

func setupHooks(cfg *config.Config, runner AgentRunner, mgr *agent.SessionManager) (*agent.Hooks, *agent.HITLManager) {
	hooks := &agent.Hooks{}
	hooks.RegisterPostDispatch(agent.NewHandoffHook(cfg.StorageRoot()))

	var hitl *agent.HITLManager
	if cfg.Channels.Telegram.Enabled {
		token := cfg.TelegramToken()
		api, err := newTgAPI(token, cfg.Channels.Telegram.AllowFrom, cfg)
		if err != nil {
			slog.Error("telegram: connection failed (Gateway will still run)", "err", err)
		} else if cfg.HumanInTheLoop() {
			hitl = agent.NewHITLManager(api, []string{"shell_exec", "send_email"})
			hooks.RegisterPreTool(hitl.PreToolHook)
			slog.Info("run: human-in-the-loop (HITL) enabled")
		}
	}

	policyPath := agent.ResolvePolicyFilePath(cfg.PolicyFilePath(), cfg.StorageRoot())
	policy, err := agent.NewFilePolicy(policyPath)
	if err != nil {
		slog.Warn("run: policy file load failed, using allow-all", "err", err)
		policy = agent.AllowAllPolicy{}
	}
	policyHook := agent.NewPolicyHook(policy, hitl)
	hooks.RegisterPreTool(policyHook.PreToolHook)

	mgr.SetHooks(hooks)
	runner.SetHooks(hooks)
	return hooks, hitl
}

func setupConsolidator(cfg *config.Config, stack *agentStack, mgr *agent.SessionManager, handler *dispatchHandler, otelProvider *observability.Provider) {
	if stack.memStore == nil {
		return
	}
	h := consolidator.New(stack.runner, stack.memStore, stack.vecStore, stack.embedProv)
	if cfg.Agents.Defaults.Compaction.Strategy == "memoryFlush" {
		h.SetPrompt(cfg.Agents.Defaults.Compaction.MemoryFlush.Prompt)
		h.SetTTL(cfg.Agents.Defaults.Compaction.MemoryFlush.TTL)
		h.SetGlobalTTL(cfg.Agents.Defaults.Compaction.MemoryFlush.GlobalTTL)
		h.SetGlobalPatterns(cfg.Agents.Defaults.Compaction.MemoryFlush.GlobalNamespacePatterns)
	}
	if otelProvider != nil {
		h.SetObservability(otelProvider)
	}
	handler.consolidator = h
	mgr.SetConsolidator(h)
	slog.Info("run: memory consolidation enabled")
}

func setupGateHandler(store *agentctx.CheckpointManager, handler *dispatchHandler) bot.Handler {
	if store == nil {
		return handler
	}
	pairingStore, err := agentctx.NewPairingStore(store.DB())
	if err != nil {
		slog.Warn("run: pairing store unavailable, DM pairing disabled", "err", err)
		return handler
	}
	slog.Info("run: DM pairing enabled")
	return bot.NewPairingHandler(pairingStore, handler)
}

func startGateway(ctx context.Context, cfg *config.Config, store *agentctx.CheckpointManager, memStore *memory.MemoryStore, gateHandler bot.Handler, wg *sync.WaitGroup) {
	res := dash.Resources{
		Config:      cfg,
		Checkpoints: store,
		Memory:      memStore,
		Version:     version,
	}
	gw := gateway.NewServer(cfg.Gateway, gateHandler, res)
	wg.Add(1)
	go func() {
		defer wg.Done()
		if err := gw.ListenAndServe(ctx); err != nil && !errors.Is(err, context.Canceled) {
			slog.Error("gateway: server error", "err", err)
		}
	}()
}

func startTelegramBot(cfg *config.Config, token string, gateHandler bot.Handler, tracer *observability.DispatchTracer) *bot.Bot {
	api, err := newTgAPI(token, cfg.Channels.Telegram.AllowFrom, cfg)
	if err != nil {
		slog.Warn("run: telegram API failed to initialize, bot will not be started", "err", err)
		return nil
	}
	b := bot.New(api, gateHandler)
	b.SetTracer(tracer)
	return b
}

func startCron(ctx context.Context, cfg *config.Config, stack *agentStack, b *bot.Bot, tracer *observability.DispatchTracer, wg *sync.WaitGroup) {
	cronMgr := stack.NewSessionManager(cfg, nil, tracer)
	cronDisp := &cronDispatcher{
		mgr:          cronMgr,
		b:            b,
		storageRoot:  cfg.StorageRoot(),
		secretsRoot:  cfg.SecretsRoot(),
		userEmail:    cfg.Strategic.UserEmail,
		vecStore:     stack.vecStore,
		embedProv:    stack.embedProv,
		workspaceDir: cfg.WorkspacePath(""),
	}
	scheduler := cron.NewScheduler(cfg.WorkspacePath("", "jobs.json"), cfg.WorkspacePath("", "jobs"), cronDisp)
	wg.Add(1)
	go func() {
		defer wg.Done()
		defer func() {
			if r := recover(); r != nil {
				_, _ = os.Stderr.WriteString("PANIC IN CRON: " + fmt.Sprint(r) + "\n")
				os.Exit(1)
			}
		}()
		if err := scheduler.Run(ctx); err != nil && !errors.Is(err, context.Canceled) {
			slog.Error("cron scheduler stopped", "err", err)
		}
	}()
}

func startHeartbeat(ctx context.Context, cfg *config.Config, token string, wg *sync.WaitGroup) {
	var alertChatID int64
	if len(cfg.Channels.Telegram.AllowFrom) > 0 {
		alertChatID, _ = strconv.ParseInt(cfg.Channels.Telegram.AllowFrom[0], 10, 64)
	}
	gmailSecretsPath := filepath.Join(cfg.SecretsRoot(), "gmail")
	api, _ := newTgAPI(token, nil, cfg) // Heartbeat uses its own transient API if needed
	hb := newHeartbeatRunner(liveProbes(), api, alertChatID, cfg.StorageRoot(), cfg.GeminiAPIKey(), token, gmailSecretsPath)
	wg.Add(1)
	go func() {
		defer wg.Done()
		defer func() {
			if r := recover(); r != nil {
				_, _ = os.Stderr.WriteString("PANIC IN HEARTBEAT: " + fmt.Sprint(r) + "\n")
				os.Exit(1)
			}
		}()
		hb.Run(ctx)
	}()
	slog.Info("gobot: heartbeat started", "interval", "15m")
}

// drainGoroutines waits for the WaitGroup to complete or times out.
// F-074: Drain goroutines with configurable timeout.
func drainGoroutines(wg *sync.WaitGroup, timeout time.Duration) {
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
