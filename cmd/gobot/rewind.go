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
		RunE: func(cmd *cobra.Command, _ []string) error {
			if snapshotName == "" {
				return cmd.Help()
			}
			return runRestore(snapshotName)
		},
	}

	cmd.Flags().StringVar(&snapshotName, "snapshot", "", "Snapshot name to restore")
	cmd.AddCommand(cmdRewindList())
	return cmd
}

func cmdRewindList() *cobra.Command {
	return &cobra.Command{
		Use:   "list",
		Short: "List available session snapshots",
		RunE: func(_ *cobra.Command, _ []string) error {
			return runListSnapshots()
		},
	}
}

func runRestore(snapshotName string) error {
	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("config: %w", err)
	}

	if err := agent.RestoreSnapshot(cfg.StorageRoot(), snapshotName); err != nil {
		return fmt.Errorf("restore snapshot: %w", err)
	}

	fmt.Printf("Successfully restored session state from snapshot: %s\n", snapshotName)
	return nil
}

func runListSnapshots() error {
	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("config: %w", err)
	}

	snapshots, err := agent.ListSnapshots(cfg.StorageRoot())
	if err != nil {
		return fmt.Errorf("list snapshots: %w", err)
	}

	if len(snapshots) == 0 {
		fmt.Println("No snapshots found.")
		return nil
	}

	printSnapshots(snapshots)
	return nil
}

func printSnapshots(snapshots []agent.SnapshotMetadata) {
	fmt.Printf("%-35s  %-20s  %-10s  %s\n", "NAME", "TIMESTAMP", "TASK ID", "GIT SHA")
	fmt.Println(strings.Repeat("-", 100))

	limit := len(snapshots)
	if limit > 10 {
		limit = 10
	}

	for i := 0; i < limit; i++ {
		s := snapshots[i]
		ts := s.Timestamp
		if len(ts) > 19 {
			ts = ts[:19]
		}
		sha := s.GitSHA
		if len(sha) > 7 {
			sha = sha[:7]
		}
		fmt.Printf("%-35s  %-20s  %-10s  %s\n", s.Name, ts, s.TaskID, sha)
	}
}
