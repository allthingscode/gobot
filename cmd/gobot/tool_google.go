package main

import (
	"context"
	"fmt"
	"strings"

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

func (t *ListCalendarTool) Name() string { return listCalendarToolName }

func (t *ListCalendarTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        listCalendarToolName,
		Description: "List upcoming Google Calendar events. Returns a Markdown-formatted list of events ordered by start time.",
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"days_ahead": map[string]any{
					"type":        "integer",
					"description": "How many days ahead to look for events. Defaults to 7.",
				},
				"max_results": map[string]any{
					"type":        "integer",
					"description": "Maximum number of events to return. Defaults to 10.",
				},
			},
			"required": []string{},
		},
	}
}

func (t *ListCalendarTool) Execute(_ context.Context, _ string, args map[string]any) (string, error) {
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

func (t *ListTasksTool) Name() string { return listTasksToolName }

func (t *ListTasksTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        listTasksToolName,
		Description: "List open (incomplete) Google Tasks. Returns a Markdown-formatted checklist of pending tasks.",
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"tasklist_id": map[string]any{
					"type":        "string",
					"description": "The task list ID to query. Defaults to \"@default\" (the user's default list).",
				},
			},
			"required": []string{},
		},
	}
}

func (t *ListTasksTool) Execute(_ context.Context, _ string, args map[string]any) (string, error) {
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

func (t *CreateTaskTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        createTaskToolName,
		Description: "Create a new task in Google Tasks. Returns a confirmation with the task title and its assigned ID.",
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"title": map[string]any{
					"type":        "string",
					"description": "The title of the task to create. Required.",
				},
				"notes": map[string]any{
					"type":        "string",
					"description": "Optional notes or description to attach to the task.",
				},
				"tasklist_id": map[string]any{
					"type":        "string",
					"description": "The task list ID to add the task to. Defaults to \"@default\".",
				},
			},
			"required": []string{"title"},
		},
	}
}

func (t *CreateTaskTool) Execute(_ context.Context, _ string, args map[string]any) (string, error) {
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

func (t *CompleteTaskTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        completeTaskToolName,
		Description: "Mark a Google Task as completed. Use the task ID returned by list_tasks.",
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"task_id": map[string]any{
					"type":        "string",
					"description": "The ID of the task to complete. Required.",
				},
				"tasklist_id": map[string]any{
					"type":        "string",
					"description": "The task list ID. Defaults to \"@default\".",
				},
			},
			"required": []string{"task_id"},
		},
	}
}

func (t *CompleteTaskTool) Execute(_ context.Context, _ string, args map[string]any) (string, error) {
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

func (t *UpdateTaskTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        updateTaskToolName,
		Description: "Update an existing Google Task's title, notes, or due date. Use the task ID returned by list_tasks. Only provide the fields you want to change.",
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"task_id": map[string]any{
					"type":        "string",
					"description": "The ID of the task to update. Required.",
				},
				"title": map[string]any{
					"type":        "string",
					"description": "New title for the task. Omit to leave unchanged.",
				},
				"notes": map[string]any{
					"type":        "string",
					"description": "New notes for the task. Omit to leave unchanged.",
				},
				"due": map[string]any{
					"type":        "string",
					"description": "New due date in RFC3339 format (e.g. 2026-04-01T00:00:00Z). Omit to leave unchanged.",
				},
				"tasklist_id": map[string]any{
					"type":        "string",
					"description": "The task list ID. Defaults to \"@default\".",
				},
			},
			"required": []string{"task_id"},
		},
	}
}

func (t *UpdateTaskTool) Execute(_ context.Context, _ string, args map[string]any) (string, error) {
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

func (t *CreateCalendarEventTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        createCalendarEventToolName,
		Description: "Create a new event in a Google Calendar.",
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"calendar_id": map[string]any{
					"type":        "string",
					"description": "The calendar ID to create the event in. Defaults to \"primary\".",
				},
				"summary": map[string]any{
					"type":        "string",
					"description": "The title/summary of the event. Required.",
				},
				"description": map[string]any{
					"type":        "string",
					"description": "Optional description or notes for the event.",
				},
				"start_time": map[string]any{
					"type":        "string",
					"description": "Start time in ISO 8601 / RFC3339 format (e.g. 2026-04-05T10:00:00-05:00). Required.",
				},
				"end_time": map[string]any{
					"type":        "string",
					"description": "End time in ISO 8601 / RFC3339 format (e.g. 2026-04-05T11:00:00-05:00). Required.",
				},
				"location": map[string]any{
					"type":        "string",
					"description": "Optional location for the event.",
				},
			},
			"required": []string{"summary", "start_time", "end_time"},
		},
	}
}

func (t *CreateCalendarEventTool) Execute(_ context.Context, _ string, args map[string]any) (string, error) {
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

func (t *WebSearchTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        webSearchToolName,
		Description: "Perform a live web search using Google Custom Search. Returns a list of titles, links, and snippets from the top results.",
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"query": map[string]any{
					"type":        "string",
					"description": "The search query. Required.",
				},
			},
			"required": []string{"query"},
		},
	}
}

func (t *WebSearchTool) Execute(ctx context.Context, _ string, args map[string]any) (string, error) {
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
