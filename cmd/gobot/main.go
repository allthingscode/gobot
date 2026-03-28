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

	"github.com/spf13/cobra"
	"google.golang.org/genai"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/cron"
	"github.com/allthingscode/gobot/internal/doctor"
	"github.com/allthingscode/gobot/internal/gmail"
)

const version = "0.1.0"

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
	)

	if err := root.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func cmdVersion() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print gobot version and Go runtime info",
		Run: func(cmd *cobra.Command, args []string) {
			fmt.Printf("gobot %s\n", version)
			fmt.Printf("go runtime: %s\n", goVersion())
		},
	}
}

func cmdInit() *cobra.Command {
	return &cobra.Command{
		Use:   "init",
		Short: "Create workspace directories on D: drive",
		RunE: func(cmd *cobra.Command, args []string) error {
			dirs := []string{
				`D:\Gobot_Storage\workspace`,
				`D:\Gobot_Storage\logs`,
				`D:\Gobot_Storage\workspace\projects`,
				`D:\Gobot_Storage\workspace\sessions`,
			}
			for _, d := range dirs {
				if err := os.MkdirAll(d, 0o755); err != nil {
					return fmt.Errorf("failed to create %s: %w", d, err)
				}
				fmt.Printf("  ok  %s\n", d)
			}
			fmt.Println("init complete.")
			return nil
		},
	}
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
			return doctor.Run(cfg)
		},
	}
}

type dispatchHandler struct {
	mgr *agent.SessionManager
}

func (h *dispatchHandler) Handle(ctx context.Context, sessionKey string, msg bot.InboundMessage) (string, error) {
	slog.Debug("handler: dispatching to session manager", "session", sessionKey)
	return h.mgr.Dispatch(ctx, sessionKey, msg.Text)
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

			// Setup logging to file and stderr
			logPath := filepath.Join(cfg.StorageRoot(), "logs", "gobot.log")
			logFile, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
			if err == nil {
				// Use a multi-writer to send logs to both file and stderr
				handler := slog.NewTextHandler(io.MultiWriter(os.Stderr, logFile), nil)
				slog.SetDefault(slog.New(handler))
				defer logFile.Close()
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
			model := cfg.Agents.Defaults.Model
			if model == "" {
				model = "gemini-3-flash-preview"
			}

			ensureAwarenessFile(cfg.StorageRoot())
			systemPrompt := loadSystemPrompt(cfg.StorageRoot())
			if systemPrompt != "" {
				slog.Info("gobot: system prompt loaded", "bytes", len(systemPrompt))
			}
			runner := newGeminiRunner(genaiClient, model, systemPrompt)

			store, storeErr := agentctx.GetCheckpointManager(cfg.StorageRoot())
			if storeErr != nil {
				slog.Warn("run: checkpoint store unavailable, running statelessly", "err", storeErr)
			}
			mgr := agent.NewSessionManager(runner, store, model)
			handler := &dispatchHandler{mgr: mgr}
			api, err := newTgAPI(token, cfg.Channels.Telegram.AllowFrom)
			if err != nil {
				return fmt.Errorf("telegram: %w", err)
			}

			b := bot.New(api, handler)

			// Start cron scheduler in background.
			storePath := filepath.Join(cfg.StorageRoot(), "workspace", "jobs.json")
			itemsDir := filepath.Join(cfg.StorageRoot(), "workspace", "jobs")
			cronDisp := &cronDispatcher{mgr: mgr, b: b, storageRoot: cfg.StorageRoot()}
			scheduler := cron.NewScheduler(storePath, itemsDir, cronDisp)
			go func() {
				if err := scheduler.Run(ctx); err != nil && err != context.Canceled {
					slog.Error("cron scheduler stopped", "err", err)
				}
			}()

			slog.Info("gobot starting", "model", model)
			return b.Run(ctx)
		},
	}
}

func cmdReauth() *cobra.Command {
	return &cobra.Command{
		Use:   "reauth",
		Short: "Check Gmail OAuth2 token status",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config: %w", err)
			}
			secretsRoot := filepath.Join(cfg.StorageRoot(), "secrets")
			_, err = gmail.NewService(secretsRoot)
			if errors.Is(err, gmail.ErrNeedsReauth) {
				fmt.Println("Gmail token expired or missing.")
				fmt.Println("Run the Python oauth tool: python -m strategery.oauth")
				return nil
			}
			if err != nil {
				return fmt.Errorf("gmail: %w", err)
			}
			fmt.Println("Gmail token OK.")
			return nil
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
			ctx := cmd.Context()
			genaiClient, err := genai.NewClient(ctx, &genai.ClientConfig{
				APIKey:  cfg.GeminiAPIKey(),
				Backend: genai.BackendGeminiAPI,
			})
			if err != nil {
				return fmt.Errorf("genai client: %w", err)
			}
			model := cfg.Agents.Defaults.Model
			if model == "" {
				model = "gemini-3-flash-preview"
			}

			systemPrompt := loadSystemPrompt(cfg.StorageRoot())
			runner := newGeminiRunner(genaiClient, model, systemPrompt)

			store, _ := agentctx.GetCheckpointManager(cfg.StorageRoot())
			mgr := agent.NewSessionManager(runner, store, model)

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
