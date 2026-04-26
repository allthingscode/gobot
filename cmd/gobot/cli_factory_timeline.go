package main

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/allthingscode/gobot/internal/factory"
	"github.com/spf13/cobra"
)

func cmdFactoryTimeline() *cobra.Command {
	var taskID string
	var asJSON bool

	cmd := &cobra.Command{
		Use:   "timeline",
		Short: "Render one task's session timeline from factory artifacts",
		RunE: func(cmd *cobra.Command, _ []string) error {
			result, err := factory.LoadTimeline(".", taskID)
			if err != nil {
				return fmt.Errorf("load timeline: %w", err)
			}

			if asJSON {
				return renderTimelineJSON(cmd, result)
			}
			renderTimelineText(cmd, result)
			return nil
		},
	}

	cmd.Flags().StringVar(&taskID, "task", "", "Task ID to render (for example C-185)")
	cmd.Flags().BoolVar(&asJSON, "json", false, "Render timeline as JSON")
	_ = cmd.MarkFlagRequired("task")

	return cmd
}

func renderTimelineJSON(cmd *cobra.Command, result factory.TimelineResult) error {
	encoder := json.NewEncoder(cmd.OutOrStdout())
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(result); err != nil {
		return fmt.Errorf("encode timeline json: %w", err)
	}
	return nil
}

func renderTimelineText(cmd *cobra.Command, result factory.TimelineResult) {
	out := cmd.OutOrStdout()
	fmt.Fprintf(out, "Task Timeline: %s\n\n", result.TaskID)
	fmt.Fprintln(out, "TIMESTAMP                    SPECIALIST   EVENT         DETAILS")
	fmt.Fprintln(out, "--------------------------------------------------------------------------")
	for _, entry := range result.Entries {
		details := timelineDetails(entry)
		fmt.Fprintf(
			out,
			"%-27s %-12s %-13s %s\n",
			entry.Timestamp.UTC().Format("2006-01-02T15:04:05Z"),
			valueOrDash(entry.Specialist),
			entry.EventType,
			details,
		)
	}
	fmt.Fprintf(out, "\nWarnings: %d\n", result.WarningCount)
}

func timelineDetails(entry factory.TimelineEntry) string {
	parts := make([]string, 0, 2)
	if entry.Source != "" || entry.Target != "" {
		parts = append(parts, fmt.Sprintf("%s -> %s", valueOrDash(entry.Source), valueOrDash(entry.Target)))
	}
	if entry.Notes != "" {
		parts = append(parts, entry.Notes)
	}
	if len(parts) == 0 {
		return "-"
	}
	return strings.Join(parts, " | ")
}

func valueOrDash(value string) string {
	if strings.TrimSpace(value) == "" {
		return "-"
	}
	return value
}
