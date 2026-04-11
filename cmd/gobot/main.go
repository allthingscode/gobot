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
	"github.com/allthingscode/gobot/internal/memory/consolidator"
	"github.com/allthingscode/gobot/internal/observability"
)

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
		cmdConfig(),
		cmdRun(),
		cmdReauth(),
		cmdCheckpoints(),
		cmdResume(),
		cmdSimulate(),
		cmdCalendar(),
		cmdTasks(),
		cmdMemory(),
		cmdEmail(),
		cmdAuthorize(),
		cmdSecrets(),
		cmdState(),
		cmdLogs(),
		cmdRewind(),
		cmdFactory(),
	)

	if err := root.Execute(); err != nil {
		var exitErr *exitCodeError
		if errors.As(err, &exitErr) {
			os.Exit(exitErr.code)
		}
		slog.Error("fatal command error", "err", err)
		os.Exit(1)
	}
}

func cmdVersion() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print gobot version and build info",
		Run: func(_ *cobra.Command, _ []string) {
			fmt.Printf("gobot version %s\n", version)
			fmt.Printf("  commit: %s\n", commitHash)
			fmt.Printf("  built:  %s\n", buildTime)
			fmt.Printf("  go:     %s\n", runtime.Version())
		},
	}
}

func cmdInit() *cobra.Command {
	var rootFlag string
	cmd := &cobra.Command{
		Use:   "init",
		Short: "Create gobot workspace directories under the configured storage root",
		RunE: func(_ *cobra.Command, _ []string) error {
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
		},
	}
	cmd.Flags().StringVar(&rootFlag, "root", "", "Custom storage root directory")
	return cmd
}

func cmdDoctor() *cobra.Command {
	var noInteractive bool
	cmd := &cobra.Command{
		Use:   "doctor",
		Short: "Run strategic health checks",
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
	cmd.Flags().BoolVar(&noInteractive, "no-interactive", false, "Skip live connectivity checks (OAuth, API calls)")
	return cmd
}

func cmdRun() *cobra.Command {
	return &cobra.Command{
		Use:   "run",
		Short: "Start the strategic agent polling loop",
		RunE: func(cmd *cobra.Command, _ []string) error {
			defer func() {
				if r := recover(); r != nil {
					_, _ = os.Stderr.WriteString("PANIC CAUGHT IN MAIN: " + fmt.Sprint(r) + "\n")
					os.Exit(1)
				}
			}()
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config: %w", err)
			}

			// Setup logging to timestamped file and stderr
			devMode := cfg.Strategic.Observability.DevMode
			var baseHandler slog.Handler
			var logFileErr error
			if devMode {
				// Dev mode: colorized console output only (no log file).
				baseHandler = observability.NewTintedHandler(os.Stderr, slog.LevelDebug)
			} else {
				now := time.Now().Format("20060102_150405")
				logName := fmt.Sprintf("gobot_%s.log", now)
				logPath := cfg.LogPath(logName)
				logFile, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
				logFileErr = err
				if logFileErr == nil {
					// Use a multi-writer to send logs to both file and stderr
					baseHandler = slog.NewTextHandler(io.MultiWriter(os.Stderr, logFile), nil)
					defer func() { _ = logFile.Close() }()
				} else {
					baseHandler = slog.NewTextHandler(os.Stderr, nil)
				}
			}
			// Always install redaction and OTel trace correlation.
			// NewSlogHandler injects trace_id/span_id from the active OTel span (F-093).
			slog.SetDefault(slog.New(observability.NewSlogHandler(audit.NewRedactingHandler(baseHandler))))
			if logFileErr != nil {
				slog.Warn("failed to open log file, logging to stderr only", "err", logFileErr)
			}

			// Pre-flight diagnostics — mirrors gobot strategic_launcher.py
			if err := doctor.Run(cfg, nil); err != nil {
				slog.Warn("pre-flight diagnostics found issues", "err", err)
			}

			// Validate configuration after log setup so warnings are logged
			if err := reportConfigValidation(cfg, os.Stderr); err != nil {
				return err
			}

			// Prioritize token from config.json, then environment.
			token := cfg.TelegramToken()
			if token == "" && cfg.Channels.Telegram.Enabled {
				return fmt.Errorf("telegram token not set: add channels.telegram.token to config or set TELEGRAM_BOT_TOKEN env var")
			}
			ctx := cmd.Context()

			// F-074: Graceful shutdown with goroutine drain
			var wg sync.WaitGroup

			stack, cleanup, err := buildAgentStack(ctx, cfg)
			if err != nil {
				return err
			}
			defer cleanup()

			model := stack.model
			memStore := stack.memStore

			// Init OpenTelemetry observability (F-022)
			otelConfig := observability.Config{
				ServiceName:    cfg.Strategic.Observability.ServiceName,
				ServiceVersion: version, // build version
				OTLPEndpoint:   cfg.Strategic.Observability.OTLPEndpoint,
				SamplingRate:   cfg.Strategic.Observability.SamplingRate,
			}
			otelProvider, otelErr := observability.NewProvider(otelConfig)
			if otelErr != nil {
				slog.Warn("run: observability provider failed to initialize", "err", otelErr)
			} else if otelProvider != nil {
				// F-074: Use fresh context for shutdown since ctx may be cancelled
				defer func() {
					shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
					defer cancel()
					if err := otelProvider.Shutdown(shutdownCtx); err != nil {
						slog.Warn("gobot: telemetry shutdown failed", "err", err)
					}
				}()
			}
			tracer := observability.NewDispatchTracer(otelProvider)

			runner := stack.runner
			runner.SetTracer(tracer)

			store, storeErr := agentctx.GetCheckpointManager(cfg.StorageRoot())
			if storeErr != nil {
				slog.Warn("run: checkpoint store unavailable, running statelessly", "err", storeErr)
			}

			// Initialize idempotency store for side-effecting tools (F-069).
			if storeErr == nil {
				// Get the underlying db from checkpoint manager.
				db := store.DB()
				idempStore := agentctx.NewIdempotencyStore(db, cfg.EffectiveIdempotencyTTL())
				runner.SetIdempotencyStore(idempStore)

				// Periodic cleanup of expired keys (run at startup).
				if cleaned, cleanErr := idempStore.CleanupExpired(); cleanErr == nil && cleaned > 0 {
					slog.Info("run: cleaned up expired idempotency keys", "count", cleaned)
				}

				// Periodic cleanup of expired keys (background loop).
				// F-069: Ensure table doesn't grow unbounded on 24/7 servers.
				wg.Add(1)
				go func() {
					defer wg.Done()
					runIdempotencyCleanup(ctx, idempStore, 6*time.Hour)
				}()
			}

			mgr := stack.NewSessionManager(cfg, store, tracer)

			slog.Info("run: configuration loaded",
				"storage_root", cfg.StorageRoot(),
				"telegram_enabled", cfg.Channels.Telegram.Enabled,
				"gateway_enabled", cfg.Gateway.Enabled)

			// F-012: create shared Hooks instance and wire into both SessionManager and runner.
			hooks := &agent.Hooks{}

			// F-063: Automated Handoffs
			hooks.RegisterPostDispatch(agent.NewHandoffHook(cfg.StorageRoot()))

			var api *tgAPI
			var hitl *agent.HITLManager
			if cfg.Channels.Telegram.Enabled {
				var tgErr error
				api, tgErr = newTgAPI(token, cfg.Channels.Telegram.AllowFrom, cfg)
				if tgErr != nil {
					slog.Error("telegram: connection failed (Gateway will still run)", "err", tgErr)
				} else {
					// F-048: HITL Approval Framework
					if cfg.HumanInTheLoop() {
						hitl = agent.NewHITLManager(api, []string{"shell_exec", "send_email"})
						hooks.RegisterPreTool(hitl.PreToolHook)
						slog.Info("run: human-in-the-loop (HITL) enabled")
					} else {
						slog.Info("run: human-in-the-loop (HITL) disabled by config")
					}
				}
			} else {
				slog.Info("run: telegram disabled by config")
			}

			mgr.SetHooks(hooks)
			runner.SetHooks(hooks)
			handler := &dispatchHandler{mgr: mgr, memory: memStore, hitl: hitl}
			if memStore != nil {
				h := consolidator.New(runner, memStore, stack.vecStore, stack.embedProv)
				if cfg.Agents.Defaults.Compaction.Strategy == "memoryFlush" {
					h.SetPrompt(cfg.Agents.Defaults.Compaction.MemoryFlush.Prompt)
					h.SetTTL(cfg.Agents.Defaults.Compaction.MemoryFlush.TTL)
					h.SetGlobalTTL(cfg.Agents.Defaults.Compaction.MemoryFlush.GlobalTTL)
					h.SetGlobalPatterns(cfg.Agents.Defaults.Compaction.MemoryFlush.GlobalNamespacePatterns)
				}
				// Wire observability provider for metrics (F-068)
				if otelProvider != nil {
					h.SetObservability(otelProvider)
				}
				handler.consolidator = h
				mgr.SetConsolidator(h)
				slog.Info("run: memory consolidation enabled")
			}

			// Wrap handler with HITL and Pairing gates
			var gateHandler bot.Handler = handler

			if store != nil {
				if pairingStore, pErr := agentctx.NewPairingStore(store.DB()); pErr != nil {
					slog.Warn("run: pairing store unavailable, DM pairing disabled", "err", pErr)
				} else {
					gateHandler = bot.NewPairingHandler(pairingStore, handler)
					slog.Info("run: DM pairing enabled")
				}
			}

			// Start HTTP Gateway if enabled (F-046)
			if cfg.Gateway.Enabled {
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

			// Start Telegram bot if enabled
			var b *bot.Bot
			if cfg.Channels.Telegram.Enabled {
				if api != nil {
					b = bot.New(api, gateHandler)
					b.SetTracer(tracer)
				} else {
					slog.Warn("run: telegram API is nil, bot will not be started")
				}
			}

			// Start cron scheduler in background.
			storePath := cfg.WorkspacePath("jobs.json")
			itemsDir := cfg.WorkspacePath("jobs")
			// Cron jobs use an ephemeral session manager (nil store) so they never
			// share checkpoint history with DM conversations (F-013).
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
			scheduler := cron.NewScheduler(storePath, itemsDir, cronDisp)
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
			// Start health heartbeat in background (F-023).
			{
				var alertChatID int64
				if len(cfg.Channels.Telegram.AllowFrom) > 0 {
					alertChatID, _ = strconv.ParseInt(cfg.Channels.Telegram.AllowFrom[0], 10, 64)
				}
				gmailSecretsPath := filepath.Join(cfg.SecretsRoot(), "gmail")
				// Heartbeat can run without API (it just won't send alerts)
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

			slog.Info("gobot starting", "model", model)
			if b != nil {
				return b.Run(ctx)
			}

			// If no blocking bot is running (e.g., Telegram disabled),
			// block on context cancellation to keep the Gateway/Cron/Heartbeat alive.
			slog.Info("gobot running (headless mode)")
			<-ctx.Done()
			slog.Info("gobot: signal received, draining goroutines...")

			// F-074: Drain goroutines with 30-second timeout
			drainGoroutines(&wg, 30*time.Second)

			return nil
		},
	}
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
