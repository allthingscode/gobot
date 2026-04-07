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
	"strconv"
	"strings"
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
	"github.com/allthingscode/gobot/internal/integrations/google"

	"github.com/allthingscode/gobot/internal/memory"
	"github.com/allthingscode/gobot/internal/memory/consolidator"
	"github.com/allthingscode/gobot/internal/observability"
	"github.com/allthingscode/gobot/internal/provider"
	"github.com/allthingscode/gobot/internal/resilience"
	"sync"
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
			fmt.Printf("  go:     %s\n", goVersion())
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
				cfg.WorkspacePath(),
				cfg.WorkspacePath("jobs"),
				cfg.WorkspacePath("journal"),
				cfg.WorkspacePath("sessions"),
				cfg.WorkspacePath("projects"),
				cfg.WorkspacePath("reports"),
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

type dispatchHandler struct {
	mgr          *agent.SessionManager
	memory       *memory.MemoryStore        // may be nil
	consolidator *consolidator.Consolidator // may be nil
	hitl         *agent.HITLManager         // may be nil
}

func (h *dispatchHandler) Handle(ctx context.Context, sessionKey string, msg bot.InboundMessage) (string, error) {
	// Handle admin commands first.
	if strings.TrimSpace(msg.Text) == "/reset_circuits" {
		resilience.ResetAll()
		slog.Info("resilience: all circuit breakers reset by user", "session", sessionKey)
		return "All circuit breakers have been reset.", nil
	}

	slog.Debug("handler: dispatching to session manager", "session", sessionKey)
	reply, err := h.mgr.Dispatch(ctx, sessionKey, msg.Text)
	if err != nil {
		if errors.Is(err, resilience.ErrCircuitOpen) {
			return "I'm sorry, I'm currently having trouble connecting to one of my services. Please try again in a few moments.", nil
		}
	}
	if err == nil && h.memory != nil {
		// Index user message (if not generic noise)
		if !memory.ShouldSkipRAG(msg.Text) {
			_ = h.memory.Index(sessionKey, "USER: "+msg.Text)
		}
		// Index assistant reply
		if reply != "" {
			if indexErr := h.memory.Index(sessionKey, "ASSISTANT: "+reply); indexErr != nil {
				slog.Warn("memory: index failed", "session", sessionKey, "err", indexErr)
			}
		}
	}
	if err == nil && h.consolidator != nil && reply != "" {
		h.consolidator.ConsolidateAsync(sessionKey, reply)
	}
	return reply, err
}

func (h *dispatchHandler) HandleCallback(ctx context.Context, cb bot.InboundCallback) error {
	if h.hitl != nil {
		return h.hitl.HandleCallback(ctx, cb)
	}
	return nil
}

const (
	sendEmailToolName    = "send_email"
	readTextFileToolName = "read_text_file"
)

// ReadTextFileTool implements Tool and reads a file from the workspace.
type ReadTextFileTool struct {
	workspace string
}

func (t *ReadTextFileTool) Name() string { return readTextFileToolName }
func (t *ReadTextFileTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        readTextFileToolName,
		Description: "Read the complete contents of a text file from the workspace.",
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"path": map[string]any{
					"type":        "string",
					"description": "The absolute or relative path to the file.",
				},
			},
			"required": []string{"path"},
		},
	}
}

func (t *ReadTextFileTool) Execute(ctx context.Context, _ string, args map[string]any) (string, error) {
	path, _ := args["path"].(string)
	if path == "" {
		return "", fmt.Errorf("read_text_file: path is required")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read_text_file: %w", err)
	}
	return string(data), nil
}

// registerTools initializes all tools (spawn, shell, MCP, google, etc) and returns them.
func registerTools(cfg *config.Config, prov provider.Provider, model string, memStore *memory.MemoryStore) []Tool {
	specialistModels := make(map[string]string, len(cfg.Agents.Specialists))
	for agentType, sc := range cfg.Agents.Specialists {
		if sc.Model != "" {
			specialistModels[agentType] = sc.Model
		}
	}

	// Register tools.
	secretsRoot := cfg.SecretsRoot()
	tools := []Tool{
		newSpawnTool(prov, model, nil, specialistModels, memStore, cfg),
		&ReadTextFileTool{workspace: cfg.WorkspacePath()},
	}
	tools = append(tools, newShellExecTool(cfg.WorkspacePath(), cfg.ExecTimeout()))

	// Initialize MCP tools from config
	for name, srvCfg := range cfg.Tools.MCPServers {
		env := cfg.MCPEnvFor(name)
		tools = append(tools, newMCPTool(name, srvCfg, env))
		slog.Info("run: registered MCP tool", "server", name)
	}

	if memStore != nil {
		tools = append(tools, newSearchMemoryTool(memStore))
	}
	tools = append(tools, []Tool{
		newListCalendarTool(secretsRoot),
		newCreateCalendarEventTool(secretsRoot),
		newListTasksTool(secretsRoot),
		newCreateTaskTool(secretsRoot),
		newCompleteTaskTool(secretsRoot),
		newUpdateTaskTool(secretsRoot),
	}...)

	googleKey := cfg.GoogleAPIKey()
	googleCX := cfg.GoogleCX()
	if googleKey != "" && googleCX != "" {
		tools = append(tools, newWebSearchTool(googleKey, googleCX))
		slog.Info("run: registered google_search tool")
	} else {
		slog.Warn("run: google_search tool disabled -- providers.google.apiKey or customCx not set")
	}

	if userEmail := cfg.Strategic.UserEmail; userEmail != "" {
		tools = append(tools, newSendEmailTool(secretsRoot, cfg.StorageRoot(), userEmail))
		tools = append(tools, newSearchGmailTool(secretsRoot))
		tools = append(tools, newReadGmailTool(secretsRoot))
		slog.Info("run: registered gmail tools (send, search, read)")
	} else {
		slog.Warn("run: send_email tool disabled -- strategic_edition.user_email not set in config")
	}
	return tools
}

func cmdRun() *cobra.Command {
	return &cobra.Command{
		Use:   "run",
		Short: "Start the strategic agent polling loop",
		RunE: func(cmd *cobra.Command, _ []string) error {
			defer func() {
				if r := recover(); r != nil {
					os.Stderr.WriteString("PANIC CAUGHT IN MAIN: " + fmt.Sprint(r) + "\n")
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
					defer logFile.Close()
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
				h := consolidator.New(runner, memStore)
				if cfg.Agents.Defaults.Compaction.Strategy == "memoryFlush" {
					h.SetPrompt(cfg.Agents.Defaults.Compaction.MemoryFlush.Prompt)
					h.SetTTL(cfg.Agents.Defaults.Compaction.MemoryFlush.TTL)
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
				gw := gateway.NewServer(cfg.Gateway, gateHandler)
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
				mgr:         cronMgr,
				b:           b,
				storageRoot: cfg.StorageRoot(),
				secretsRoot: cfg.SecretsRoot(),
				userEmail:   cfg.Strategic.UserEmail,
			}
			scheduler := cron.NewScheduler(storePath, itemsDir, cronDisp)
			wg.Add(1)
			go func() {
				defer wg.Done()
				defer func() {
					if r := recover(); r != nil {
						os.Stderr.WriteString("PANIC IN CRON: " + fmt.Sprint(r) + "\n")
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
							os.Stderr.WriteString("PANIC IN HEARTBEAT: " + fmt.Sprint(r) + "\n")
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

func cmdReauth() *cobra.Command {
	return &cobra.Command{
		Use:   "reauth",
		Short: "Interactive Google/Gmail OAuth2 re-authorization",
		RunE: func(_ *cobra.Command, _ []string) error {
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config: %w", err)
			}
			secretsRoot := cfg.SecretsRoot()

			// Scopes required for gobot
			scopes := []string{
				"https://www.googleapis.com/auth/tasks",
				"https://www.googleapis.com/auth/calendar.readonly",
				"https://www.googleapis.com/auth/google.send",
				"https://www.googleapis.com/auth/google.readonly",
			}

			fmt.Println("Starting Go-native interactive authorization...")
			return google.AuthorizeInteractive(secretsRoot, scopes)
		},
	}
}

func cmdCheckpoints() *cobra.Command {
	return &cobra.Command{
		Use:   "checkpoints",
		Short: "List resumable agent sessions",
		RunE: func(_ *cobra.Command, _ []string) error {
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config: %w", err)
			}
			store, err := agentctx.GetCheckpointManager(cfg.StorageRoot())
			if err != nil {
				return fmt.Errorf("checkpoint store: %w", err)
			}
			threads, err := store.ListResumable()
			if err != nil {
				return fmt.Errorf("list checkpoints: %w", err)
			}
			if len(threads) == 0 {
				fmt.Println("No resumable checkpoints found.")
				return nil
			}
			fmt.Printf("%-40s  %-22s  %-10s  %s\n", "THREAD ID", "LAST ACTIVE", "ITERATION", "MODEL")
			fmt.Printf("%-40s  %-22s  %-10s  %s\n",
				"----------------------------------------",
				"----------------------",
				"----------",
				"-----")
			for _, t := range threads {
				fmt.Printf("%-40s  %-22s  %-10d  %s\n",
					t.ThreadID, t.UpdatedAt, t.LatestIteration, t.Model)
			}
			return nil
		},
	}
}

// resumePreviewLines is the maximum number of messages to print in resume preview.
const resumePreviewLines = 6

func cmdResume() *cobra.Command {
	return &cobra.Command{
		Use:   "resume <thread-id>",
		Short: "Show the last messages from a saved session",
		Args:  cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			threadID := args[0]
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config: %w", err)
			}
			store, err := agentctx.GetCheckpointManager(cfg.StorageRoot())
			if err != nil {
				return fmt.Errorf("checkpoint store: %w", err)
			}
			snap, err := store.LoadLatest(threadID)
			if err != nil {
				return fmt.Errorf("load checkpoint: %w", err)
			}
			if snap == nil {
				fmt.Printf("No checkpoint found for thread: %s\n", threadID)
				return nil
			}
			fmt.Printf("Thread:    %s\n", threadID)
			fmt.Printf("Model:     %s\n", snap.Model)
			fmt.Printf("Iteration: %d\n", snap.Iteration)
			fmt.Printf("Messages:  %d total\n\n", len(snap.Messages))

			// Print the last resumePreviewLines messages.
			msgs := snap.Messages
			if len(msgs) > resumePreviewLines {
				msgs = msgs[len(msgs)-resumePreviewLines:]
				fmt.Printf("... (showing last %d messages)\n\n", resumePreviewLines)
			}
			for _, m := range msgs {
				text := extractMessageText(m)
				if len(text) > 200 {
					text = text[:200] + "..."
				}
				fmt.Printf("[%s] %s\n\n", m.Role, text)
			}
			fmt.Printf("To continue this session, send a message from Telegram using session key: %s\n", threadID)
			return nil
		},
	}
}

func cmdSimulate() *cobra.Command {
	return &cobra.Command{
		Use:   "simulate <prompt>",
		Short: "Simulate a user message locally",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			prompt := args[0]
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config: %w", err)
			}

			// Pre-flight diagnostics — mirrors gobot strategic_launcher.py
			if err := doctor.Run(cfg, nil); err != nil {
				slog.Warn("pre-flight diagnostics found issues", "err", err)
			}

			ctx := cmd.Context()
			stack, cleanup, err := buildAgentStack(ctx, cfg)
			if err != nil {
				return err
			}
			defer cleanup()

			runner := stack.runner

			// F-012: create shared Hooks instance
			hooks := &agent.Hooks{}
			// F-063: Automated Handoffs
			hooks.RegisterPostDispatch(agent.NewHandoffHook(cfg.StorageRoot()))

			store, _ := agentctx.GetCheckpointManager(cfg.StorageRoot())
			mgr := stack.NewSessionManager(cfg, store, nil)
			mgr.SetHooks(hooks)
			runner.SetHooks(hooks)

			fmt.Printf("--- Simulating Prompt ---\n%s\n\n", prompt)
			fmt.Println("Waiting for response...")
			reply, err := mgr.Dispatch(ctx, "cli-sim", prompt)
			if err != nil {
				return fmt.Errorf("dispatch: %w", err)
			}

			fmt.Printf("\n--- Agent Response ---\n%s\n", reply)
			return nil
		},
	}
}

func cmdCalendar() *cobra.Command {
	var maxResults int
	cmd := &cobra.Command{
		Use:   "calendar",
		Short: "List upcoming Google Calendar events",
		RunE: func(_ *cobra.Command, _ []string) error {
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config: %w", err)
			}
			secretsRoot := cfg.SecretsRoot()
			events, err := google.ListUpcomingEvents(secretsRoot, maxResults)
			if err != nil {
				return fmt.Errorf("calendar: %w", err)
			}
			if len(events) == 0 {
				fmt.Println("No upcoming events.")
				return nil
			}
			for _, ev := range events {
				marker := ""
				if ev.AllDay {
					marker = " (all day)"
				}
				loc := ""
				if ev.Location != "" {
					loc = "  @ " + ev.Location
				}
				fmt.Printf("%s%s  %s%s\n", ev.Start, marker, ev.Summary, loc)
			}
			return nil
		},
	}
	cmd.Flags().IntVarP(&maxResults, "max", "n", 10, "maximum number of events to show")
	return cmd
}

func cmdTasks() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "tasks",
		Short: "Manage Google Tasks",
	}

	listCmd := &cobra.Command{
		Use:   "list",
		Short: "List open tasks",
		RunE: func(_ *cobra.Command, _ []string) error {
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config: %w", err)
			}
			secretsRoot := cfg.SecretsRoot()
			tasks, err := google.ListTasks(secretsRoot, "@default")
			if err != nil {
				return fmt.Errorf("tasks: %w", err)
			}
			if len(tasks) == 0 {
				fmt.Println("No open tasks.")
				return nil
			}
			for _, task := range tasks {
				due := ""
				if task.Due != "" {
					due = "  (due " + task.Due[:10] + ")"
				}
				fmt.Printf("[ ] %s%s\n", task.Title, due)
			}
			return nil
		},
	}

	addCmd := &cobra.Command{
		Use:   "add <title>",
		Short: "Create a new task",
		Args:  cobra.MinimumNArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config: %w", err)
			}
			secretsRoot := cfg.SecretsRoot()
			title := strings.Join(args, " ")
			id, err := google.CreateTask(secretsRoot, "@default", title, "")
			if err != nil {
				return fmt.Errorf("create task: %w", err)
			}
			fmt.Printf("Task created: %s (id: %s)\n", title, id)
			return nil
		},
	}

	cmd.AddCommand(listCmd, addCmd)
	return cmd
}

func cmdMemory() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "memory",
		Short: "Manage long-term memory index",
	}

	rebuildCmd := &cobra.Command{
		Use:   "rebuild",
		Short: "Re-index all session logs from workspace/sessions into the memory database",
		RunE: func(_ *cobra.Command, _ []string) error {
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config: %w", err)
			}
			store, err := memory.NewMemoryStore(cfg.StorageRoot())
			if err != nil {
				return fmt.Errorf("memory store: %w", err)
			}
			defer store.Close()
			sessionDir := cfg.WorkspacePath("sessions")
			n, err := store.Rebuild(sessionDir)
			if err != nil {
				return fmt.Errorf("rebuild: %w", err)
			}
			fmt.Printf("Memory index rebuilt: %d session files indexed.\n", n)
			return nil
		},
	}

	cmd.AddCommand(rebuildCmd)

	searchCmd := &cobra.Command{
		Use:   "search <query>",
		Short: "Search the memory index for a query",
		Args:  cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			query := args[0]
			cfg, err := config.Load()
			if err != nil {
				return err
			}
			store, err := memory.NewMemoryStore(cfg.StorageRoot())
			if err != nil {
				return err
			}
			defer store.Close()
			results, err := store.Search(query, 10)
			if err != nil {
				return err
			}
			if len(results) == 0 {
				fmt.Println("No results found.")
				return nil
			}
			for i, r := range results {
				fmt.Printf("[%d] %s (%s)\n", i+1, r["content"], r["timestamp"])
			}
			return nil
		},
	}
	cmd.AddCommand(searchCmd)
	return cmd
}

// runIdempotencyCleanup runs periodic background cleanup of expired idempotency keys.
// F-069: Periodic cleanup to prevent unbounded SQLite growth.
func runIdempotencyCleanup(ctx context.Context, store *agentctx.IdempotencyStore, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			cleaned, err := store.CleanupExpired()
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

func cmdEmail() *cobra.Command {
	return &cobra.Command{
		Use:   "email <subject> <body>",
		Short: "Send a manual test email",
		Args:  cobra.ExactArgs(2),
		RunE: func(_ *cobra.Command, args []string) error {
			subject := args[0]
			body := args[1]
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config: %w", err)
			}
			secretsRoot := cfg.SecretsRoot()
			userEmail := cfg.Strategic.UserEmail
			if userEmail == "" {
				return fmt.Errorf("strategic_edition.user_email not set in config")
			}

			// Gmail service uses secretsRoot/gmail/token.json
			gmailSecrets := filepath.Join(secretsRoot, "gmail")
			svc, err := google.NewService(gmailSecrets)
			if err != nil {
				return fmt.Errorf("auth: %w", err)
			}

			fmt.Printf("Sending test email to %s...\n", userEmail)
			if err := svc.Send(context.Background(), userEmail, subject, body); err != nil {
				return err
			}
			fmt.Println("Success! Email sent.")
			return nil
		},
	}
}

func cmdAuthorize() *cobra.Command {
	return &cobra.Command{
		Use:   "authorize <code-or-chat-id>",
		Short: "Authorize a Telegram user by pairing code or numeric chat ID",
		Args:  cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			arg := args[0]
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config: %w", err)
			}
			store, err := agentctx.GetCheckpointManager(cfg.StorageRoot())
			if err != nil {
				return fmt.Errorf("checkpoint store: %w", err)
			}
			pairingStore, err := agentctx.NewPairingStore(store.DB())
			if err != nil {
				return fmt.Errorf("pairing store: %w", err)
			}

			// Try as a pairing code first.
			if chatID, err := pairingStore.AuthorizeByCode(arg); err == nil {
				fmt.Printf("Authorized chat ID %d via pairing code.\n", chatID)
				return nil
			}

			// Fall back to direct chat ID authorization.
			chatID, err := strconv.ParseInt(arg, 10, 64)
			if err != nil {
				return fmt.Errorf("authorize: %q is not a valid pairing code or numeric chat ID", arg)
			}
			if err := pairingStore.AuthorizeByChatID(chatID, "operator"); err != nil {
				return fmt.Errorf("authorize: %w", err)
			}
			fmt.Printf("Authorized chat ID %d directly.\n", chatID)
			return nil
		},
	}
}

// extractMessageText returns the plain-text content of a StrategicMessage.
func extractMessageText(m agentctx.StrategicMessage) string {
	if m.Content == nil {
		return "(no content)"
	}
	if m.Content.Str != nil {
		return *m.Content.Str
	}
	for _, item := range m.Content.Items {
		if item.Text != nil {
			return item.Text.Text
		}
	}
	return "(no text content)"
}
