package main

import (
	"context"
	"errors"
	"fmt"
	"io"
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
		RunE: func(cmd *cobra.Command, _ []string) error {
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config: %w", err)
			}
			events, err := google.ListUpcomingEvents(cmd.Context(), cfg.SecretsRoot(), maxResults)
			return printCalendarEvents(cmd.OutOrStdout(), events, err)
		},
	}
	cmd.Flags().IntVarP(&maxResults, "max", "n", 10, "maximum number of events to show")
	return cmd
}

// printCalendarEvents writes the ListUpcomingEvents result. A partial result is
// printed with a trailing warning; any other error is returned unprinted.
func printCalendarEvents(w io.Writer, events []google.CalendarEvent, err error) error {
	var incomplete *google.CalendarIncompleteError
	if err != nil && !errors.As(err, &incomplete) {
		return fmt.Errorf("calendar: %w", err)
	}
	if len(events) == 0 && incomplete == nil {
		fmt.Fprintln(w, "No upcoming events.")
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
		fmt.Fprintf(w, "%s%s  %s%s\n", ev.Start, marker, ev.Summary, loc)
	}
	if incomplete != nil {
		if len(events) == 0 {
			fmt.Fprintln(w, "No upcoming events in the calendars that loaded.")
		}
		fmt.Fprintf(w, "WARNING: incomplete schedule; could not load calendar(s): %s\n", strings.Join(incomplete.Failed, ", "))
	}
	return nil
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
