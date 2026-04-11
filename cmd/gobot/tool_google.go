package main

import (
	"context"
	"fmt"
	"strings"

	"github.com/spf13/cobra"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/integrations/google"
	"github.com/allthingscode/gobot/internal/provider"
)

// ── ListCalendarTool ───────────────────────────────────────────────────────────

const listCalendarToolName = "list_calendar_events"

// ListCalendarTool fetches upcoming Google Calendar events and returns them as
// formatted Markdown. The days_ahead parameter is declared for Gemini's benefit
// but is not forwarded to the API (ListUpcomingEvents does not accept a date
// range); max_results is used as the hard cap instead.
type ListCalendarTool struct {
	secretsRoot string
}

func newListCalendarTool(secretsRoot string) *ListCalendarTool {
	return &ListCalendarTool{secretsRoot: secretsRoot}
}

type listCalendarArgs struct {
	DaysAhead  int `json:"days_ahead,omitempty" schema:"How many days ahead to look for events. Defaults to 7."`
	MaxResults int `json:"max_results,omitempty" schema:"Maximum number of events to return. Defaults to 10."`
}

func (t *ListCalendarTool) Name() string { return listCalendarToolName }

func (t *ListCalendarTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        listCalendarToolName,
		Description: "List upcoming Google Calendar events. Returns a Markdown-formatted list of events ordered by start time.",
		Parameters:  agent.DeriveSchema(listCalendarArgs{}),
	}
}

func (t *ListCalendarTool) Execute(_ context.Context, _, _ string, args map[string]any) (string, error) {
	maxResults := 10
	if v, ok := args["max_results"]; ok {
		switch n := v.(type) {
		case float64:
			maxResults = int(n)
		case int:
			maxResults = n
		case int64:
			maxResults = int(n)
		}
	}
	if maxResults <= 0 {
		maxResults = 10
	}

	events, err := google.ListUpcomingEvents(t.secretsRoot, maxResults)
	if err != nil {
		return "", fmt.Errorf("list_calendar_events: %w", err)
	}
	if len(events) == 0 {
		return "No upcoming calendar events found.", nil
	}
	return google.FormatEventsMarkdown(events), nil
}

// ── ListTasksTool ──────────────────────────────────────────────────────────────

const listTasksToolName = "list_tasks"

// ListTasksTool fetches open Google Tasks and returns them as formatted Markdown.
type ListTasksTool struct {
	secretsRoot string
}

func newListTasksTool(secretsRoot string) *ListTasksTool {
	return &ListTasksTool{secretsRoot: secretsRoot}
}

type listTasksArgs struct {
	TasklistID string `json:"tasklist_id,omitempty" schema:"The task list ID to query. Defaults to \"@default\" (the user's default list)."`
}

func (t *ListTasksTool) Name() string { return listTasksToolName }

func (t *ListTasksTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        listTasksToolName,
		Description: "List open (incomplete) Google Tasks. Returns a Markdown-formatted checklist of pending tasks.",
		Parameters:  agent.DeriveSchema(listTasksArgs{}),
	}
}

func (t *ListTasksTool) Execute(_ context.Context, _, _ string, args map[string]any) (string, error) {
	tasklistID := "@default"
	if v, ok := args["tasklist_id"]; ok {
		if s, _ := v.(string); s != "" {
			tasklistID = s
		}
	}

	tasks, err := google.ListTasks(t.secretsRoot, tasklistID)
	if err != nil {
		return "", fmt.Errorf("list_tasks: %w", err)
	}
	if len(tasks) == 0 {
		return "No open tasks found.", nil
	}
	return google.FormatTasksMarkdown(tasks), nil
}

// ── CreateTaskTool ─────────────────────────────────────────────────────────────

const createTaskToolName = "create_task"

// CreateTaskTool creates a new Google Task and returns a confirmation string.
type CreateTaskTool struct {
	secretsRoot string
}

func newCreateTaskTool(secretsRoot string) *CreateTaskTool {
	return &CreateTaskTool{secretsRoot: secretsRoot}
}

func (t *CreateTaskTool) Name() string { return createTaskToolName }

type createTaskArgs struct {
	Title      string `json:"title" schema:"The title of the task to create. Required."`
	Notes      string `json:"notes,omitempty" schema:"Optional notes or description to attach to the task."`
	TasklistID string `json:"tasklist_id,omitempty" schema:"The task list ID to add the task to. Defaults to \"@default\"."`
}

func (t *CreateTaskTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        createTaskToolName,
		Description: "Create a new task in Google Tasks. Returns a confirmation with the task title and its assigned ID.",
		Parameters:  agent.DeriveSchema(createTaskArgs{}),
	}
}

func (t *CreateTaskTool) Execute(_ context.Context, _, _ string, args map[string]any) (string, error) {
	title, _ := args["title"].(string)
	if strings.TrimSpace(title) == "" {
		return "", fmt.Errorf("create_task: title is required")
	}

	notes, _ := args["notes"].(string)

	tasklistID := "@default"
	if v, ok := args["tasklist_id"]; ok {
		if s, _ := v.(string); s != "" {
			tasklistID = s
		}
	}

	id, err := google.CreateTask(t.secretsRoot, tasklistID, title, notes)
	if err != nil {
		return "", fmt.Errorf("create_task: %w", err)
	}
	return fmt.Sprintf("Task created: %s (id: %s)", title, id), nil
}

// -- CompleteTaskTool -----------------------------------------------------------

const completeTaskToolName = "complete_task"

type CompleteTaskTool struct{ secretsRoot string }

func newCompleteTaskTool(secretsRoot string) *CompleteTaskTool {
	return &CompleteTaskTool{secretsRoot: secretsRoot}
}

func (t *CompleteTaskTool) Name() string { return completeTaskToolName }

type completeTaskArgs struct {
	TaskID     string `json:"task_id" schema:"The ID of the task to complete. Required."`
	TasklistID string `json:"tasklist_id,omitempty" schema:"The task list ID. Defaults to \"@default\"."`
}

func (t *CompleteTaskTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        completeTaskToolName,
		Description: "Mark a Google Task as completed. Use the task ID returned by list_tasks.",
		Parameters:  agent.DeriveSchema(completeTaskArgs{}),
	}
}

func (t *CompleteTaskTool) Execute(_ context.Context, _, _ string, args map[string]any) (string, error) {
	taskID, _ := args["task_id"].(string)
	if strings.TrimSpace(taskID) == "" {
		return "", fmt.Errorf("complete_task: task_id is required")
	}
	tasklistID, _ := args["tasklist_id"].(string)
	if err := google.CompleteTask(t.secretsRoot, tasklistID, taskID); err != nil {
		return "", fmt.Errorf("complete_task: %w", err)
	}
	return fmt.Sprintf("Task %s marked as completed.", taskID), nil
}

// -- UpdateTaskTool -------------------------------------------------------------

const updateTaskToolName = "update_task"

type UpdateTaskTool struct{ secretsRoot string }

func newUpdateTaskTool(secretsRoot string) *UpdateTaskTool {
	return &UpdateTaskTool{secretsRoot: secretsRoot}
}

func (t *UpdateTaskTool) Name() string { return updateTaskToolName }

type updateTaskArgs struct {
	TaskID     string `json:"task_id" schema:"The ID of the task to update. Required."`
	Title      string `json:"title,omitempty" schema:"New title for the task. Omit to leave unchanged."`
	Notes      string `json:"notes,omitempty" schema:"New notes for the task. Omit to leave unchanged."`
	Due        string `json:"due,omitempty" schema:"New due date in RFC3339 format (e.g. 2026-04-01T00:00:00Z). Omit to leave unchanged."`
	TasklistID string `json:"tasklist_id,omitempty" schema:"The task list ID. Defaults to \"@default\"."`
}

func (t *UpdateTaskTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        updateTaskToolName,
		Description: "Update an existing Google Task's title, notes, or due date. Use the task ID returned by list_tasks. Only provide the fields you want to change.",
		Parameters:  agent.DeriveSchema(updateTaskArgs{}),
	}
}

func (t *UpdateTaskTool) Execute(_ context.Context, _, _ string, args map[string]any) (string, error) {
	taskID, _ := args["task_id"].(string)
	if strings.TrimSpace(taskID) == "" {
		return "", fmt.Errorf("update_task: task_id is required")
	}
	tasklistID, _ := args["tasklist_id"].(string)
	title, _ := args["title"].(string)
	notes, _ := args["notes"].(string)
	due, _ := args["due"].(string)

	if err := google.UpdateTask(t.secretsRoot, tasklistID, taskID, title, notes, due); err != nil {
		return "", fmt.Errorf("update_task: %w", err)
	}
	return fmt.Sprintf("Task %s updated.", taskID), nil
}

// ── CreateCalendarEventTool ────────────────────────────────────────────────────

const createCalendarEventToolName = "create_calendar_event"

// CreateCalendarEventTool creates a new event in a Google Calendar.
type CreateCalendarEventTool struct {
	secretsRoot string
}

func newCreateCalendarEventTool(secretsRoot string) *CreateCalendarEventTool {
	return &CreateCalendarEventTool{secretsRoot: secretsRoot}
}

func (t *CreateCalendarEventTool) Name() string { return createCalendarEventToolName }

type createCalendarEventArgs struct {
	CalendarID  string `json:"calendar_id,omitempty" schema:"The calendar ID to create the event in. Defaults to \"primary\"."`
	Summary     string `json:"summary" schema:"The title/summary of the event. Required."`
	Description string `json:"description,omitempty" schema:"Optional description or notes for the event."`
	StartTime   string `json:"start_time" schema:"Start time in ISO 8601 / RFC3339 format (e.g. 2026-04-05T10:00:00-05:00). Required."`
	EndTime     string `json:"end_time" schema:"End time in ISO 8601 / RFC3339 format (e.g. 2026-04-05T11:00:00-05:00). Required."`
	Location    string `json:"location,omitempty" schema:"Optional location for the event."`
}

func (t *CreateCalendarEventTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        createCalendarEventToolName,
		Description: "Create a new event in a Google Calendar.",
		Parameters:  agent.DeriveSchema(createCalendarEventArgs{}),
	}
}

func (t *CreateCalendarEventTool) Execute(_ context.Context, _, _ string, args map[string]any) (string, error) {
	summary, _ := args["summary"].(string)
	if strings.TrimSpace(summary) == "" {
		return "", fmt.Errorf("create_calendar_event: summary is required")
	}
	startTime, _ := args["start_time"].(string)
	if strings.TrimSpace(startTime) == "" {
		return "", fmt.Errorf("create_calendar_event: start_time is required")
	}
	endTime, _ := args["end_time"].(string)
	if strings.TrimSpace(endTime) == "" {
		return "", fmt.Errorf("create_calendar_event: end_time is required")
	}

	calendarID, _ := args["calendar_id"].(string)
	description, _ := args["description"].(string)
	location, _ := args["location"].(string)

	id, err := google.CreateEvent(t.secretsRoot, calendarID, summary, description, startTime, endTime, location)
	if err != nil {
		return "", fmt.Errorf("create_calendar_event: %w", err)
	}
	return fmt.Sprintf("Event created: %s (id: %s)", summary, id), nil
}

// ── WebSearchTool ─────────────────────────────────────────────────────────────

const webSearchToolName = "google_search"

// WebSearchTool performs a web search using Google Custom Search API.
type WebSearchTool struct {
	apiKey  string
	cx      string
	baseURL string
}

func newWebSearchTool(apiKey, cx string) *WebSearchTool {
	return &WebSearchTool{
		apiKey:  apiKey,
		cx:      cx,
		baseURL: google.DefaultBaseURL,
	}
}

func (t *WebSearchTool) Name() string { return webSearchToolName }

type webSearchArgs struct {
	Query string `json:"query" schema:"The search query. Required."`
}

func (t *WebSearchTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        webSearchToolName,
		Description: "Perform a live web search using Google Custom Search. Returns a list of titles, links, and snippets from the top results.",
		Parameters:  agent.DeriveSchema(webSearchArgs{}),
	}
}

func (t *WebSearchTool) Execute(ctx context.Context, _, _ string, args map[string]any) (string, error) {
	query, _ := args["query"].(string)
	if strings.TrimSpace(query) == "" {
		return "", fmt.Errorf("google_search: query is required")
	}

	svc := &google.SearchService{
		BaseURL:    t.baseURL,
		HTTPClient: google.DefaultSearchClient,
	}
	results, err := svc.Execute(ctx, t.apiKey, t.cx, query)
	if err != nil {
		return "", fmt.Errorf("google_search: %w", err)
	}

	return google.FormatSearchMarkdown(results), nil
}

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
			events, err := google.ListUpcomingEvents(secretsRoot, maxResults)
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
			tasks, err := google.ListTasks(secretsRoot, "@default")
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
			title := strings.Join(args, " ")
			id, err := google.CreateTask(secretsRoot, "@default", title, "")
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
