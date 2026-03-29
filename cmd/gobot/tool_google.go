package main

import (
	"context"
	"fmt"
	"strings"

	"google.golang.org/genai"

	"github.com/allthingscode/gobot/internal/google"
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

func (t *ListCalendarTool) Declaration() *genai.FunctionDeclaration {
	return &genai.FunctionDeclaration{
		Name:        listCalendarToolName,
		Description: "List upcoming Google Calendar events. Returns a Markdown-formatted list of events ordered by start time.",
		Parameters: &genai.Schema{
			Type: genai.TypeObject,
			Properties: map[string]*genai.Schema{
				"days_ahead": {
					Type:        genai.TypeInteger,
					Description: "How many days ahead to look for events. Defaults to 7.",
				},
				"max_results": {
					Type:        genai.TypeInteger,
					Description: "Maximum number of events to return. Defaults to 10.",
				},
			},
			Required: []string{},
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

func (t *ListTasksTool) Declaration() *genai.FunctionDeclaration {
	return &genai.FunctionDeclaration{
		Name:        listTasksToolName,
		Description: "List open (incomplete) Google Tasks. Returns a Markdown-formatted checklist of pending tasks.",
		Parameters: &genai.Schema{
			Type: genai.TypeObject,
			Properties: map[string]*genai.Schema{
				"tasklist_id": {
					Type:        genai.TypeString,
					Description: "The task list ID to query. Defaults to \"@default\" (the user's default list).",
				},
			},
			Required: []string{},
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

func (t *CreateTaskTool) Declaration() *genai.FunctionDeclaration {
	return &genai.FunctionDeclaration{
		Name:        createTaskToolName,
		Description: "Create a new task in Google Tasks. Returns a confirmation with the task title and its assigned ID.",
		Parameters: &genai.Schema{
			Type: genai.TypeObject,
			Properties: map[string]*genai.Schema{
				"title": {
					Type:        genai.TypeString,
					Description: "The title of the task to create. Required.",
				},
				"notes": {
					Type:        genai.TypeString,
					Description: "Optional notes or description to attach to the task.",
				},
				"tasklist_id": {
					Type:        genai.TypeString,
					Description: "The task list ID to add the task to. Defaults to \"@default\".",
				},
			},
			Required: []string{"title"},
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

func (t *CompleteTaskTool) Declaration() *genai.FunctionDeclaration {
	return &genai.FunctionDeclaration{
		Name:        completeTaskToolName,
		Description: "Mark a Google Task as completed. Use the task ID returned by list_tasks.",
		Parameters: &genai.Schema{
			Type: genai.TypeObject,
			Properties: map[string]*genai.Schema{
				"task_id": {
					Type:        genai.TypeString,
					Description: "The ID of the task to complete. Required.",
				},
				"tasklist_id": {
					Type:        genai.TypeString,
					Description: "The task list ID. Defaults to \"@default\".",
				},
			},
			Required: []string{"task_id"},
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

func (t *UpdateTaskTool) Declaration() *genai.FunctionDeclaration {
	return &genai.FunctionDeclaration{
		Name:        updateTaskToolName,
		Description: "Update an existing Google Task's title, notes, or due date. Use the task ID returned by list_tasks. Only provide the fields you want to change.",
		Parameters: &genai.Schema{
			Type: genai.TypeObject,
			Properties: map[string]*genai.Schema{
				"task_id": {
					Type:        genai.TypeString,
					Description: "The ID of the task to update. Required.",
				},
				"title": {
					Type:        genai.TypeString,
					Description: "New title for the task. Omit to leave unchanged.",
				},
				"notes": {
					Type:        genai.TypeString,
					Description: "New notes for the task. Omit to leave unchanged.",
				},
				"due": {
					Type:        genai.TypeString,
					Description: "New due date in RFC3339 format (e.g. 2026-04-01T00:00:00Z). Omit to leave unchanged.",
				},
				"tasklist_id": {
					Type:        genai.TypeString,
					Description: "The task list ID. Defaults to \"@default\".",
				},
			},
			Required: []string{"task_id"},
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
