package main

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/secrets"
)

func cmdSecrets() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "secrets",
		Short: "Manage DPAPI-encrypted secrets",
	}
	cmd.AddCommand(
		cmdSecretsSet(),
		cmdSecretsGet(),
		cmdSecretsList(),
		cmdSecretsDelete(),
	)
	return cmd
}

func cmdSecretsSet() *cobra.Command {
	return &cobra.Command{
		Use:   "set <key> <value>",
		Short: "Encrypt and store a secret",
		Args:  cobra.ExactArgs(2),
		RunE: func(_ *cobra.Command, args []string) error {
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config: %w", err)
			}
			store := secrets.NewSecretsStore(cfg.StorageRoot())
			if err := store.Set(args[0], args[1]); err != nil {
				return fmt.Errorf("set secret: %w", err)
			}
			fmt.Printf("Secret %q stored.\n", args[0])
			return nil
		},
	}
}

func cmdSecretsGet() *cobra.Command {
	return &cobra.Command{
		Use:   "get <key>",
		Short: "Decrypt and print a secret",
		Args:  cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config: %w", err)
			}
			store := secrets.NewSecretsStore(cfg.StorageRoot())
			val, err := store.Get(args[0])
			if err != nil {
				return fmt.Errorf("get secret: %w", err)
			}
			if val == "" {
				fmt.Printf("Secret %q not found.\n", args[0])
				return nil
			}
			fmt.Println(val)
			return nil
		},
	}
}

func cmdSecretsList() *cobra.Command {
	return &cobra.Command{
		Use:   "list",
		Short: "List stored secret keys",
		RunE: func(_ *cobra.Command, _ []string) error {
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config: %w", err)
			}
			store := secrets.NewSecretsStore(cfg.StorageRoot())
			keys, err := store.List()
			if err != nil {
				return fmt.Errorf("list secrets: %w", err)
			}
			if len(keys) == 0 {
				fmt.Println("No secrets stored.")
				return nil
			}
			for _, k := range keys {
				fmt.Println(k)
			}
			return nil
		},
	}
}

func cmdSecretsDelete() *cobra.Command {
	return &cobra.Command{
		Use:   "delete <key>",
		Short: "Delete a stored secret",
		Args:  cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config: %w", err)
			}
			store := secrets.NewSecretsStore(cfg.StorageRoot())
			if err := store.Delete(args[0]); err != nil {
				return fmt.Errorf("delete secret: %w", err)
			}
			fmt.Printf("Secret %q deleted.\n", args[0])
			return nil
		},
	}
}
