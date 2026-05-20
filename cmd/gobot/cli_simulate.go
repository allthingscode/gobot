package main

import (
	"fmt"

	"github.com/allthingscode/gobot/internal/config"
	"github.com/spf13/cobra"
)

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

			mgr, cleanup, err := newCLISessionManager(cmd.Context(), cfg, cliHooksModeSimulate)
			if err != nil {
				return err
			}
			defer cleanup()

			fmt.Printf("--- Simulating Prompt ---\n%s\n\n", prompt)
			fmt.Println("Waiting for response...")
			reply, err := mgr.Dispatch(cmd.Context(), "cli-sim", "cli-user", prompt)
			if err != nil {
				return fmt.Errorf("dispatch: %w", err)
			}

			fmt.Printf("\n--- Agent Response ---\n%s\n", reply)
			return nil
		},
	}
}
