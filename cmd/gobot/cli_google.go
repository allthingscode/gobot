package main

import (
	"context"
	"fmt"
	"strings"

	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/integrations/google"
	"github.com/spf13/cobra"
)

func cmdCalendar() *cobra.Command {
	var maxResults int
	cmd := &cobra.Command{
		Use:   "calendar",
		Short: "List upcoming Google Calendar events",
		RunE: func(_ *cobra.Command, _ []string) error {
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config: %w", err)
			}
			secretsRoot := cfg.SecretsRoot()
			ctx := context.Background()
			events, err := google.ListUpcomingEvents(ctx, secretsRoot, maxResults)
			if err != nil {
				return fmt.Errorf("calendar: %w", err)
			}
			if len(events) == 0 {
				fmt.Println("No upcoming events.")
				return nil
			}
			for _, ev := range events {
				marker := ""
				if ev.AllDay {
					marker = " (all day)"
				}
				loc := ""
				if ev.Location != "" {
					loc = "  @ " + ev.Location
				}
				fmt.Printf("%s%s  %s%s\n", ev.Start, marker, ev.Summary, loc)
			}
			return nil
		},
	}
	cmd.Flags().IntVarP(&maxResults, "max", "n", 10, "maximum number of events to show")
	return cmd
}

func cmdTasks() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "tasks",
		Short: "Manage Google Tasks",
	}

	listCmd := &cobra.Command{
		Use:   "list",
		Short: "List open tasks",
		RunE: func(_ *cobra.Command, _ []string) error {
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config: %w", err)
			}
			secretsRoot := cfg.SecretsRoot()
			ctx := context.Background()
			tasks, err := google.ListTasks(ctx, secretsRoot, "@default")
			if err != nil {
				return fmt.Errorf("tasks: %w", err)
			}
			if len(tasks) == 0 {
				fmt.Println("No open tasks.")
				return nil
			}
			for _, task := range tasks {
				due := ""
				if task.Due != "" {
					due = "  (due " + task.Due[:10] + ")"
				}
				fmt.Printf("[ ] %s%s\n", task.Title, due)
			}
			return nil
		},
	}

	addCmd := &cobra.Command{
		Use:   "add <title>",
		Short: "Create a new task",
		Args:  cobra.MinimumNArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config: %w", err)
			}
			secretsRoot := cfg.SecretsRoot()
			ctx := context.Background()
			title := strings.Join(args, " ")
			id, err := google.CreateTask(ctx, secretsRoot, "@default", title, "")
			if err != nil {
				return fmt.Errorf("create task: %w", err)
			}
			fmt.Printf("Task created: %s (id: %s)\n", title, id)
			return nil
		},
	}

	cmd.AddCommand(listCmd, addCmd)
	return cmd
}
