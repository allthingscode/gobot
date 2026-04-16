package main

import (
	"fmt"
	"log/slog"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/app"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/doctor"
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

			// Pre-flight diagnostics — mirrors gobot strategic_launcher.py
			if err := doctor.Run(cfg, nil); err != nil {
				slog.Warn("pre-flight diagnostics found issues", "err", err)
			}

			ctx := cmd.Context()
			stack, cleanup, err := app.BuildAgentStack(ctx, cfg)
			if err != nil {
				return err
			}
			defer cleanup()

			runner := stack.Runner

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
			reply, err := mgr.Dispatch(ctx, "cli-sim", "cli-user", prompt)
			if err != nil {
				return fmt.Errorf("dispatch: %w", err)
			}

			fmt.Printf("\n--- Agent Response ---\n%s\n", reply)
			return nil
		},
	}
}
