package main

import (
	"context"
	"fmt"

	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/memory"
	"github.com/spf13/cobra"
)

func cmdMemory() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "memory",
		Short: "Manage long-term memory index",
	}

	cmd.AddCommand(cmdMemoryRebuild())
	cmd.AddCommand(cmdMemorySearch())
	return cmd
}

func cmdMemoryRebuild() *cobra.Command {
	return &cobra.Command{
		Use:   "rebuild",
		Short: "Re-index all session logs from workspace/sessions into the memory database",
		RunE: func(_ *cobra.Command, _ []string) error {
			return runMemoryRebuild()
		},
	}
}

func cmdMemorySearch() *cobra.Command {
	return &cobra.Command{
		Use:   "search <query>",
		Short: "Search the memory index for a query",
		Args:  cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			return runMemorySearch(args[0])
		},
	}
}

func runMemoryRebuild() error {
	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("config: %w", err)
	}
	store, err := memory.NewMemoryStore(cfg.StorageRoot())
	if err != nil {
		return fmt.Errorf("memory store: %w", err)
	}
	defer func() { _ = store.Close() }()
	sessionDir := cfg.WorkspacePath("", "sessions")
	n, err := store.Rebuild(sessionDir)
	if err != nil {
		return fmt.Errorf("rebuild: %w", err)
	}
	fmt.Printf("Memory index rebuilt: %d session files indexed.\n", n)
	return nil
}

func runMemorySearch(query string) error {
	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}
	store, err := memory.NewMemoryStore(cfg.StorageRoot())
	if err != nil {
		return fmt.Errorf("new memory store: %w", err)
	}
	defer func() { _ = store.Close() }()
	results, err := store.Search(context.Background(), query, "", 10)
	if err != nil {
		return fmt.Errorf("search memory: %w", err)
	}
	if len(results) == 0 {
		fmt.Println("No results found.")
		return nil
	}
	for i, r := range results {
		fmt.Printf("[%d] %s (%s)\n", i+1, r["content"], r["timestamp"])
	}
	return nil
}
