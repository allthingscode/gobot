package main

import (
	"fmt"
	"strconv"

	"github.com/spf13/cobra"

	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/integrations/google"
)

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
