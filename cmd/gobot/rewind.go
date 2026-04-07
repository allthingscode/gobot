package main

import (
	"fmt"
	"strings"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/config"
	"github.com/spf13/cobra"
)

func cmdRewind() *cobra.Command {
	var snapshotName string
	cmd := &cobra.Command{
		Use:   "rewind",
		Short: "Manage session checkpoints and rewind state",
		Long:  "F-081: Session Checkpoint & Rewind. Allows listing and restoring session snapshots.",
		RunE: func(cmd *cobra.Command, args []string) error {
			if snapshotName == "" {
				return cmd.Help()
			}

			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config: %w", err)
			}

			if err := agent.RestoreSnapshot(cfg.StorageRoot(), snapshotName); err != nil {
				return err
			}

			fmt.Printf("Successfully restored session state from snapshot: %s\n", snapshotName)
			return nil
		},
	}

	cmd.Flags().StringVar(&snapshotName, "snapshot", "", "Snapshot name to restore")

	listCmd := &cobra.Command{
		Use:   "list",
		Short: "List available session snapshots",
		RunE: func(_ *cobra.Command, _ []string) error {
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config: %w", err)
			}

			snapshots, err := agent.ListSnapshots(cfg.StorageRoot())
			if err != nil {
				return err
			}

			if len(snapshots) == 0 {
				fmt.Println("No snapshots found.")
				return nil
			}

			fmt.Printf("%-35s  %-20s  %-10s  %s\n", "NAME", "TIMESTAMP", "TASK ID", "GIT SHA")
			fmt.Println(strings.Repeat("-", 100))

			// Show last 10 as per spec (though ListSnapshots returns all)
			limit := len(snapshots)
			if limit > 10 {
				limit = 10
			}

			for i := 0; i < limit; i++ {
				s := snapshots[i]
				fmt.Printf("%-35s  %-20s  %-10s  %s\n",
					s.Name, s.Timestamp[:19], s.TaskID, s.GitSHA[:7])
			}
			return nil
		},
	}

	cmd.AddCommand(listCmd)
	return cmd
}
