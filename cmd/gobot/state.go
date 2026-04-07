package main

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"time"

	"github.com/spf13/cobra"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/state"
)

func cmdState() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "state",
		Short: "Manage workflow state and recovery",
		Long:  `Inspect, recover, and manage workflow states for long-running operations.`,
	}
	cmd.AddCommand(
		cmdStateList(),
		cmdStateInspect(),
		cmdStateRecover(),
		cmdStateArchive(),
	)
	return cmd
}

func cmdStateList() *cobra.Command {
	return &cobra.Command{
		Use:   "list",
		Short: "List active workflows",
		RunE: func(_ *cobra.Command, _ []string) error {
			cfg, err := config.Load()
			if err != nil {
				return err
			}
			mCfg := state.DefaultManagerConfig()
			mCfg.StateDir = filepath.Join(cfg.StorageRoot(), "state")
			manager := state.NewManager(mCfg)

			ids, err := manager.ListActive()
			if err != nil {
				return fmt.Errorf("listing workflows: %w", err)
			}

			if len(ids) == 0 {
				fmt.Println("No active workflows")
				return nil
			}

			fmt.Printf("%-20s %-12s %-20s\n", "ID", "STATUS", "UPDATED")
			fmt.Println("------------------------------------------------------")

			for _, id := range ids {
				wf, err := manager.LoadWorkflow(id)
				if err != nil {
					fmt.Printf("%-20s %-12s %s\n", id, "ERROR", err)
					continue
				}

				updated := wf.UpdatedAt.Format("2006-01-02 15:04")
				fmt.Printf("%-20s %-12s %-20s\n", id, wf.Status, updated)
			}

			return nil
		},
	}
}

func cmdStateInspect() *cobra.Command {
	return &cobra.Command{
		Use:   "inspect [workflow-id]",
		Short: "Inspect workflow state details",
		Args:  cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			id := state.WorkflowID(args[0])
			cfg, err := config.Load()
			if err != nil {
				return err
			}
			mCfg := state.DefaultManagerConfig()
			mCfg.StateDir = filepath.Join(cfg.StorageRoot(), "state")
			manager := state.NewManager(mCfg)

			wf, err := manager.LoadWithRecovery(id)
			if err != nil {
				return fmt.Errorf("loading workflow: %w", err)
			}

			fmt.Printf("Workflow ID:    %s\n", wf.ID)
			fmt.Printf("Status:         %s\n", wf.Status)
			fmt.Printf("Version:        %d\n", wf.Version)
			fmt.Printf("Created:        %s\n", wf.CreatedAt.Format(time.RFC3339))
			fmt.Printf("Updated:        %s\n", wf.UpdatedAt.Format(time.RFC3339))

			if len(wf.Data) > 0 {
				fmt.Printf("Data:\n")
				var prettyData map[string]interface{}
				if err := json.Unmarshal(wf.Data, &prettyData); err == nil {
					prettyJSON, _ := json.MarshalIndent(prettyData, "  ", "  ")
					fmt.Printf("  %s\n", string(prettyJSON))
				} else {
					fmt.Printf("  %s\n", string(wf.Data))
				}
			}

			return nil
		},
	}
}

func cmdStateRecover() *cobra.Command {
	return &cobra.Command{
		Use:   "recover [workflow-id]",
		Short: "Recover a crashed workflow",
		Args:  cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			id := state.WorkflowID(args[0])
			cfg, err := config.Load()
			if err != nil {
				return err
			}
			mCfg := state.DefaultManagerConfig()
			mCfg.StateDir = filepath.Join(cfg.StorageRoot(), "state")
			manager := state.NewManager(mCfg)
			hook := agent.NewStateHook(manager)

			wf, err := hook.RecoverWorkflow(context.Background(), id)
			if err != nil {
				return fmt.Errorf("recovering workflow: %w", err)
			}

			fmt.Printf("Recovered workflow %s\n", id)
			fmt.Printf("Status: %s\n", wf.Status)
			fmt.Printf("Version: %d\n", wf.Version)

			if wf.Status == state.StatusFailed {
				fmt.Println("\nWorkflow was running during crash. Review state before resuming.")
			}

			return nil
		},
	}
}

func cmdStateArchive() *cobra.Command {
	return &cobra.Command{
		Use:   "archive [workflow-id]",
		Short: "Archive a completed workflow",
		Args:  cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			id := state.WorkflowID(args[0])
			cfg, err := config.Load()
			if err != nil {
				return err
			}
			mCfg := state.DefaultManagerConfig()
			mCfg.StateDir = filepath.Join(cfg.StorageRoot(), "state")
			manager := state.NewManager(mCfg)

			if err := manager.Archive(id); err != nil {
				return fmt.Errorf("archiving workflow: %w", err)
			}

			fmt.Printf("Archived workflow %s\n", id)
			return nil
		},
	}
}
