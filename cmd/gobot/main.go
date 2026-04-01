// gobot - Strategic Edition agent runtime (Go)
package main

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"
	"google.golang.org/genai"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/audit"
	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/cron"
	"github.com/allthingscode/gobot/internal/doctor"
	"github.com/allthingscode/gobot/internal/gmail"
	"github.com/allthingscode/gobot/internal/google"

	"github.com/allthingscode/gobot/internal/memory"
	"github.com/allthingscode/gobot/internal/memory/consolidator"
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
		Long:  "gobot - the Go-native runtime for Nanobot Strategic Edition.",
	}

	root.AddCommand(
		cmdVersion(),
		cmdInit(),
		cmdDoctor(),
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
	)

	if err := root.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func cmdVersion() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print gobot version and build info",
		Run: func(cmd *cobra.Command, args []string) {
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
		RunE: func(cmd *cobra.Command, args []string) error {
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
	return &cobra.Command{
		Use:   "doctor",
		Short: "Run strategic health checks",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config load failed: %w", err)
			}
			return doctor.Run(cfg, liveProbes())
		},
	}
}

type dispatchHandler struct {
	mgr          *agent.SessionManager
	memory       *memory.MemoryStore        // may be nil
	consolidator *consolidator.Consolidator // may be nil
	hitl         *agent.HITLManager         // may be nil
}

func (h *dispatchHandler) Handle(ctx context.Context, sessionKey string, msg bot.InboundMessage) (string, error) {
	slog.Debug("handler: dispatching to session manager", "session", sessionKey)
	reply, err := h.mgr.Dispatch(ctx, sessionKey, msg.Text)
	if err == nil && h.memory != nil && reply != "" {
		if indexErr := h.memory.Index(sessionKey, reply); indexErr != nil {
			slog.Warn("memory: index failed", "session", sessionKey, "err", indexErr)
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

func cmdRun() *cobra.Command {
	return &cobra.Command{
		Use:   "run",
		Short: "Start the strategic agent polling loop",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config: %w", err)
			}

			// Pre-flight diagnostics â€" mirrors nanobot strategic_launcher.py
			if err := doctor.Run(cfg, nil); err != nil {
				return fmt.Errorf("pre-flight diagnostics failed: %w", err)
			}

			// Setup logging to timestamped file and stderr
			now := time.Now().Format("20060102_150405")
			logName := fmt.Sprintf("gobot_%s.log", now)
			logPath := cfg.LogPath(logName)
			logFile, logErr := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
			var baseHandler slog.Handler
			if logErr == nil {
				// Use a multi-writer to send logs to both file and stderr
				baseHandler = slog.NewTextHandler(io.MultiWriter(os.Stderr, logFile), nil)
				defer logFile.Close()
			} else {
				baseHandler = slog.NewTextHandler(os.Stderr, nil)
			}
			// Always install redaction — PII protection must not depend on log file health.
			slog.SetDefault(slog.New(audit.NewRedactingHandler(baseHandler)))
			if logErr != nil {
				slog.Warn("failed to open log file, logging to stderr only", "err", logErr)
			}

			// Prioritize token from config.json, then environment.
			token := cfg.TelegramToken()
			if token == "" {
				return fmt.Errorf("telegram token not set: add channels.telegram.token to config or set TELEGRAM_BOT_TOKEN env var")
			}
			ctx := cmd.Context()
			genaiClient, err := genai.NewClient(ctx, &genai.ClientConfig{
				APIKey:  cfg.GeminiAPIKey(),
				Backend: genai.BackendGeminiAPI,
			})
			if err != nil {
				return fmt.Errorf("genai client: %w", err)
			}
			model := cfg.DefaultModel()

			ensureAwarenessFile(cfg)
			systemPrompt := loadSystemPrompt(cfg)
			if systemPrompt != "" {
				slog.Info("gobot: system prompt loaded", "bytes", len(systemPrompt))
			}
			runner := newGeminiRunner(genaiClient, model, systemPrompt, cfg.EffectiveMaxToolIterations(), cfg.MaxTokens())

			// Init long-term memory store (non-fatal if it fails).
			memStore, memErr := memory.NewMemoryStore(cfg.StorageRoot())
			if memErr != nil {
				slog.Warn("run: memory store unavailable, running without long-term memory", "err", memErr)
			} else {
				runner.memStore = memStore
				defer memStore.Close()
			}

			// Build specialist model map from config (agent_type -> model override).
			specialistModels := make(map[string]string, len(cfg.Agents.Specialists))
			for agentType, sc := range cfg.Agents.Specialists {
				if sc.Model != "" {
					specialistModels[agentType] = sc.Model
				}
			}

			// Register tools.
			secretsRoot := cfg.SecretsRoot()
			tools := []Tool{
				newSpawnTool(genaiClient, model, nil, specialistModels, memStore, cfg.EffectiveMaxToolIterations()),
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
				newListTasksTool(secretsRoot),
				newCreateTaskTool(secretsRoot),
				newCompleteTaskTool(secretsRoot),
				newUpdateTaskTool(secretsRoot),
			}...)
			if userEmail := cfg.Strategic.UserEmail; userEmail != "" {
				tools = append(tools, newSendEmailTool(secretsRoot, userEmail))
			} else {
				slog.Warn("run: send_email tool disabled -- strategic_edition.user_email not set in config")
			}
			runner.tools = tools

			store, storeErr := agentctx.GetCheckpointManager(cfg.StorageRoot())
			if storeErr != nil {
				slog.Warn("run: checkpoint store unavailable, running statelessly", "err", storeErr)
			}
			mgr := agent.NewSessionManager(runner, store, model)
			mgr.SetMemoryWindow(cfg.MemoryWindow())
			mgr.SetStorageRoot(cfg.StorageRoot())
			mgr.SetLogger(agent.NewMarkdownLogger(cfg.StorageRoot())) // F-037

			// F-012: create shared Hooks instance and wire into both SessionManager and runner.
			hooks := &agent.Hooks{}

			api, err := newTgAPI(token, cfg.Channels.Telegram.AllowFrom)
			if err != nil {
				return fmt.Errorf("telegram: %w", err)
			}

			// F-048: HITL Approval Framework
			hitl := agent.NewHITLManager(api, []string{"shell_exec", "send_email"})
			hooks.RegisterPreTool(hitl.PreToolHook)

			mgr.SetHooks(hooks)
			runner.SetHooks(hooks)
			handler := &dispatchHandler{mgr: mgr, memory: memStore}
			if memStore != nil {
				handler.consolidator = consolidator.New(runner, memStore)
				slog.Info("run: memory consolidation enabled")
			}

			// Wrap handler with HITL and Pairing gates
			var gateHandler bot.Handler = handler

			// Add HITL callback handling to the handler chain
			// We can wrap the handler or let dispatchHandler implement HandleCallback
			handler.hitl = hitl

			if store != nil {
				if pairingStore, pErr := agentctx.NewPairingStore(store.DB()); pErr != nil {
					slog.Warn("run: pairing store unavailable, DM pairing disabled", "err", pErr)
				} else {
					gateHandler = bot.NewPairingHandler(pairingStore, handler)
					slog.Info("run: DM pairing enabled")
				}
			}

			b := bot.New(api, gateHandler)

			// Start cron scheduler in background.
			storePath := cfg.WorkspacePath("jobs.json")
			itemsDir := cfg.WorkspacePath("jobs")
			// Cron jobs use an ephemeral session manager (nil store) so they never
			// share checkpoint history with DM conversations (F-013).
			cronMgr := agent.NewSessionManager(runner, nil, model)
			cronDisp := &cronDispatcher{mgr: cronMgr, b: b, storageRoot: cfg.StorageRoot()}
			scheduler := cron.NewScheduler(storePath, itemsDir, cronDisp)
			go func() {
				if err := scheduler.Run(ctx); err != nil && err != context.Canceled {
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
				hb := newHeartbeatRunner(liveProbes(), api, alertChatID, cfg.StorageRoot(), cfg.GeminiAPIKey(), token, gmailSecretsPath)
				go hb.Run(ctx)
				slog.Info("gobot: heartbeat started", "interval", "15m")
			}

			slog.Info("gobot starting", "model", model)
			return b.Run(ctx)
		},
	}
}

func cmdReauth() *cobra.Command {
	return &cobra.Command{
		Use:   "reauth",
		Short: "Interactive Google/Gmail OAuth2 re-authorization",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config: %w", err)
			}
			secretsRoot := cfg.SecretsRoot()

			// Scopes required for gobot
			scopes := []string{
				"https://www.googleapis.com/auth/tasks",
				"https://www.googleapis.com/auth/calendar.readonly",
				"https://www.googleapis.com/auth/gmail.send",
				"https://www.googleapis.com/auth/gmail.readonly",
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
		RunE: func(cmd *cobra.Command, args []string) error {
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
		RunE: func(cmd *cobra.Command, args []string) error {
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

			// Pre-flight diagnostics â€" mirrors nanobot strategic_launcher.py
			if err := doctor.Run(cfg, nil); err != nil {
				return fmt.Errorf("pre-flight diagnostics failed: %w", err)
			}

			ctx := cmd.Context()
			genaiClient, err := genai.NewClient(ctx, &genai.ClientConfig{
				APIKey:  cfg.GeminiAPIKey(),
				Backend: genai.BackendGeminiAPI,
			})
			if err != nil {
				return fmt.Errorf("genai client: %w", err)
			}
			model := cfg.DefaultModel()

			systemPrompt := loadSystemPrompt(cfg)
			runner := newGeminiRunner(genaiClient, model, systemPrompt, cfg.EffectiveMaxToolIterations(), cfg.MaxTokens())

			store, _ := agentctx.GetCheckpointManager(cfg.StorageRoot())
			mgr := agent.NewSessionManager(runner, store, model)
			mgr.SetMemoryWindow(cfg.MemoryWindow())

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
		RunE: func(cmd *cobra.Command, args []string) error {
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
		RunE: func(cmd *cobra.Command, args []string) error {
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
		RunE: func(cmd *cobra.Command, args []string) error {
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
		RunE: func(cmd *cobra.Command, args []string) error {
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
	return cmd
}

func cmdEmail() *cobra.Command {
	return &cobra.Command{
		Use:   "email <subject> <body>",
		Short: "Send a manual test email",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
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
			svc, err := gmail.NewService(gmailSecrets)
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
		RunE: func(cmd *cobra.Command, args []string) error {
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
