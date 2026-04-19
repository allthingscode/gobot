package main

import (
	"context"
	"fmt"
	"path/filepath"

	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/integrations/google"
	"github.com/spf13/cobra"
)

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
			svc, err := google.NewService(context.Background(), gmailSecrets)
			if err != nil {
				return fmt.Errorf("auth: %w", err)
			}

			fmt.Printf("Sending test email to %s...\n", userEmail)
			if err := svc.Send(context.Background(), userEmail, subject, body); err != nil {
				return fmt.Errorf("send email: %w", err)
			}
			fmt.Println("Success! Email sent.")
			return nil
		},
	}
}
