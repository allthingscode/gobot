package main

import (
	"context"
	"fmt"

	"github.com/spf13/cobra"

	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
)

func cmdCheckpoints() *cobra.Command {
	return &cobra.Command{
		Use:   "checkpoints",
		Short: "List resumable agent sessions",
		RunE: func(_ *cobra.Command, _ []string) error {
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config: %w", err)
			}
			store, err := agentctx.GetCheckpointManager(cfg.StorageRoot())
			if err != nil {
				return fmt.Errorf("checkpoint store: %w", err)
			}
			threads, err := store.ListResumable(context.Background())
			if err != nil {
				return fmt.Errorf("list checkpoints: %w", err)
			}
			if len(threads) == 0 {
				fmt.Println("No resumable checkpoints found.")
				return nil
			}
			fmt.Printf("%-40s  %-22s  %-10s  %s\n", "THREAD ID", "LAST ACTIVE", "ITERATION", "MODEL")
			fmt.Printf("%-40s  %-22s  %-10s  %s\n",
				"----------------------------------------",
				"----------------------",
				"----------",
				"-----")
			for _, t := range threads {
				fmt.Printf("%-40s  %-22s  %-10d  %s\n",
					t.ThreadID, t.UpdatedAt, t.LatestIteration, t.Model)
			}
			return nil
		},
	}
}

// resumePreviewLines is the maximum number of messages to print in resume preview.
const resumePreviewLines = 6

func cmdResume() *cobra.Command {
	return &cobra.Command{
		Use:   "resume <thread-id>",
		Short: "Show the last messages from a saved session",
		Args:  cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			threadID := args[0]
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config: %w", err)
			}
			store, err := agentctx.GetCheckpointManager(cfg.StorageRoot())
			if err != nil {
				return fmt.Errorf("checkpoint store: %w", err)
			}
			snap, err := store.LoadLatest(context.Background(), threadID)
			if err != nil {
				return fmt.Errorf("load checkpoint: %w", err)
			}
			if snap == nil {
				fmt.Printf("No checkpoint found for thread: %s\n", threadID)
				return nil
			}
			fmt.Printf("Thread:    %s\n", threadID)
			fmt.Printf("Model:     %s\n", snap.Model)
			fmt.Printf("Iteration: %d\n", snap.Iteration)
			fmt.Printf("Messages:  %d total\n\n", len(snap.Messages))

			// Print the last resumePreviewLines messages.
			msgs := snap.Messages
			if len(msgs) > resumePreviewLines {
				msgs = msgs[len(msgs)-resumePreviewLines:]
				fmt.Printf("... (showing last %d messages)\n\n", resumePreviewLines)
			}
			for _, m := range msgs {
				text := extractMessageText(m)
				if len(text) > 200 {
					text = text[:200] + "..."
				}
				fmt.Printf("[%s] %s\n\n", m.Role, text)
			}
			fmt.Printf("To continue this session, send a message from Telegram using session key: %s\n", threadID)
			return nil
		},
	}
}

// extractMessageText returns the plain-text content of a StrategicMessage.
func extractMessageText(m agentctx.StrategicMessage) string {
	if m.Content == nil {
		return "(no content)"
	}
	if m.Content.Str != nil {
		return *m.Content.Str
	}
	for _, item := range m.Content.Items {
		if item.Text != nil {
			return item.Text.Text
		}
	}
	return "(no text content)"
}
