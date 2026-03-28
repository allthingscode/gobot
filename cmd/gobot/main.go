// gobot — Strategic Edition agent runtime (Go)
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"
	"google.golang.org/genai"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/doctor"
	"github.com/allthingscode/gobot/internal/gmail"
)

const version = "0.1.0"

func main() {
	root := &cobra.Command{
		Use:   "gobot",
		Short: "Strategic Edition agent runtime",
		Long:  "gobot — the Go-native runtime for Nanobot Strategic Edition.",
	}

	root.AddCommand(
		cmdVersion(),
		cmdInit(),
		cmdDoctor(),
		cmdRun(),
		cmdReauth(),
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
				`D:\Nanobot_Storage\workspace`,
				`D:\Nanobot_Storage\logs`,
				`D:\Nanobot_Storage\workspace\projects`,
				`D:\Nanobot_Storage\workspace\sessions`,
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
			token := os.Getenv("TELEGRAM_BOT_TOKEN")
			if token == "" {
				return fmt.Errorf("TELEGRAM_BOT_TOKEN environment variable not set")
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
				model = "gemini-2.5-flash"
			}
			runner := newGeminiRunner(genaiClient, model)
			store, storeErr := agentctx.GetCheckpointManager(cfg.StorageRoot())
			if storeErr != nil {
				slog.Warn("run: checkpoint store unavailable, running statelessly", "err", storeErr)
			}
			mgr := agent.NewSessionManager(runner, store, model)
			handler := &dispatchHandler{mgr: mgr}
			api, err := newTgAPI(token)
			if err != nil {
				return fmt.Errorf("telegram: %w", err)
			}
			slog.Info("gobot starting", "model", model)
			b := bot.New(api, handler)
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
