package app

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/integrations/google"
	"github.com/allthingscode/gobot/internal/observability"
	"github.com/allthingscode/gobot/internal/provider"
)

const (
	lookupPrimaryCalendarToolName = "lookup_primary_calendar_events"
	rescheduleCalendarToolName    = "reschedule_calendar_event"
)

type lookupPrimaryCalendarTool struct {
	secretsRoot string
	find        func(context.Context, string, string) ([]google.PrimaryCalendarEvent, error)
}

func (t *lookupPrimaryCalendarTool) Name() string { return lookupPrimaryCalendarToolName }

type lookupPrimaryCalendarArgs struct {
	Query string `json:"query" schema:"Text to find events on the primary calendar. Required. Results include event IDs and original times; present all matches for human selection."`
}

func (t *lookupPrimaryCalendarTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name: lookupPrimaryCalendarToolName, Parameters: agent.DeriveSchema(lookupPrimaryCalendarArgs{}),
		Description: "Find up to 50 matching primary-calendar events with identities. Results may be limited; never infer an event ID from a title. The human must select the exact event in the rescheduling approval.",
	}
}

func (t *lookupPrimaryCalendarTool) Execute(ctx context.Context, _, _ string, args map[string]any) (string, error) {
	query, _ := args["query"].(string)
	if strings.TrimSpace(query) == "" {
		return "", fmt.Errorf("calendar lookup: query is required")
	}
	events, err := t.find(ctx, t.secretsRoot, query)
	if err != nil {
		return "", fmt.Errorf("calendar lookup: %w", err)
	}
	result := struct {
		CalendarID string                        `json:"calendar_id"`
		Selection  string                        `json:"selection"`
		Events     []google.PrimaryCalendarEvent `json:"events"`
	}{"primary", "Up to 50 matches. Human selection required: approving a reschedule explicitly selects the displayed exact event, including when titles are ambiguous.", events}
	payload, err := json.Marshal(result)
	if err != nil {
		return "", fmt.Errorf("encode calendar matches: %w", err)
	}
	return string(payload), nil
}

type rescheduleCalendarTool struct {
	secretsRoot string
	reschedule  func(context.Context, string, string, string, string, func(context.Context, google.PrimaryCalendarEvent) error) error
}

type rescheduleCalendarArgs struct {
	CalendarID string `json:"calendar_id" schema:"Must be primary. Required."`
	EventID    string `json:"event_id" schema:"Exact event ID from primary-calendar lookup. Required. Never infer an ID from a title."`
	StartTime  string `json:"start_time" schema:"Proposed start in RFC3339 with explicit offset. Required."`
	EndTime    string `json:"end_time" schema:"Proposed end in RFC3339 with explicit offset, strictly after start. Required."`
}

func (t *rescheduleCalendarTool) Name() string { return rescheduleCalendarToolName }

func (t *rescheduleCalendarTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name: rescheduleCalendarToolName, SideEffecting: true, Parameters: agent.DeriveSchema(rescheduleCalendarArgs{}),
		Description: "Reschedule one non-recurring timed primary-calendar event. The human must select and approve the fetched exact event and proposed times through Telegram buttons. Guests are notified. Requires enabled interactive approval; no scheduled use.",
	}
}

// Execute fails closed when the feature-specific approval hook is unavailable.
func (t *rescheduleCalendarTool) Execute(context.Context, string, string, map[string]any) (string, error) {
	return "", fmt.Errorf("%w: calendar rescheduling requires the interactive approval hook", agent.ErrToolDenied)
}

func (t *rescheduleCalendarTool) executeApproved(ctx context.Context, session string, args map[string]any, hitl *agent.HITLManager) (string, error) {
	calendarID, _ := args["calendar_id"].(string)
	eventID, _ := args["event_id"].(string)
	start, _ := args["start_time"].(string)
	end, _ := args["end_time"].(string)
	if calendarID != "primary" || strings.TrimSpace(eventID) == "" {
		return "", fmt.Errorf("calendar reschedule requires calendar_id primary and an exact event_id")
	}
	if !bot.IsTelegramSession(session) || bot.IsCronSession(session) || hitl == nil {
		return "", fmt.Errorf("%w: calendar rescheduling requires interactive Telegram approval", agent.ErrToolDenied)
	}
	err := t.reschedule(ctx, t.secretsRoot, eventID, start, end, func(ctx context.Context, event google.PrimaryCalendarEvent) error {
		return approveCalendarReschedule(ctx, hitl, session, event, start, end)
	})
	if err != nil {
		return "", fmt.Errorf("calendar reschedule: %w", err)
	}
	return fmt.Sprintf("Primary calendar event %s rescheduled to %s - %s. Update notifications sent to all guests.", eventID, start, end), nil
}

func approveCalendarReschedule(ctx context.Context, hitl *agent.HITLManager, session string, event google.PrimaryCalendarEvent, start, end string) error {
	// A fresh nonce prevents persisted HITL decisions from authorizing another write.
	approval := map[string]any{
		"operation_id": rand.Text(), "calendar_id": "primary", "event_id": event.ID, "etag": event.ETag,
		"original_title": event.Summary, "original_location": event.Location,
		"original_start": event.Start.DateTime, "original_end": event.End.DateTime,
		"proposed_start": start, "proposed_end": end,
		"selection":     "Approve explicitly selects ONLY this exact event, even if lookup found multiple matches. Reject if this is not the event you intended.",
		"notifications": "All guests will receive update notifications (sendUpdates=all).",
	}
	approved, err := hitl.RequestApproval(ctx, session, rescheduleCalendarToolName, approval)
	if err != nil {
		return fmt.Errorf("calendar approval: %w", err)
	}
	if !approved {
		return fmt.Errorf("%w: calendar selection and reschedule rejected", agent.ErrToolDenied)
	}
	return nil
}

// ── ListCalendarTool ──────────────────────────────────────────────────────────────

const listCalendarToolName = "list_calendar_events"

// ListCalendarTool fetches upcoming Google Calendar events and returns them as
// formatted Markdown. The days_ahead parameter is declared for Gemini's benefit
// but is not forwarded to the API (ListUpcomingEvents does not accept a date
// range); max_results is used as the hard cap instead.
type ListCalendarTool struct {
	secretsRoot string
	tracer      *observability.DispatchTracer
}

func newListCalendarTool(secretsRoot string, tracer *observability.DispatchTracer) *ListCalendarTool {
	return &ListCalendarTool{secretsRoot: secretsRoot, tracer: tracer}
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

func (t *ListCalendarTool) Execute(ctx context.Context, _, _ string, args map[string]any) (string, error) {
	maxResults := t.parseMaxResults(args)

	var events []google.CalendarEvent
	var err error
	if t.tracer != nil {
		err = t.tracer.TraceGoogleCall(ctx, "calendar", "ListUpcomingEvents", func(ctx context.Context) error {
			var err2 error
			events, err2 = google.ListUpcomingEvents(ctx, t.secretsRoot, maxResults)
			if err2 != nil {
				return fmt.Errorf("list upcoming events: %w", err2)
			}
			return nil
		})
	} else {
		var err2 error
		events, err2 = google.ListUpcomingEvents(ctx, t.secretsRoot, maxResults)
		if err2 != nil {
			err = fmt.Errorf("list upcoming events: %w", err2)
		}
	}
	// A partial result still reaches the model, but labelled as incomplete.
	var incomplete *google.CalendarIncompleteError
	if err != nil && !errors.As(err, &incomplete) {
		return "", fmt.Errorf("list_calendar_events: %w", err)
	}
	return formatCalendarResult(events, incomplete), nil
}

// formatCalendarResult renders events as Markdown and states explicitly when
// some calendars failed, so a partial list is never presented as complete.
func formatCalendarResult(events []google.CalendarEvent, incomplete *google.CalendarIncompleteError) string {
	if incomplete == nil {
		if len(events) == 0 {
			return "No upcoming calendar events found."
		}
		return google.FormatEventsMarkdown(events)
	}
	body := google.FormatEventsMarkdown(events)
	if body == "" {
		body = "No upcoming events were found in the calendars that loaded.\n"
	}
	return body + "\n" + calendarIncompleteWarning(incomplete)
}

func calendarIncompleteWarning(incomplete *google.CalendarIncompleteError) string {
	return "WARNING: incomplete schedule. These calendars could not be loaded: " +
		strings.Join(incomplete.Failed, ", ") +
		". Their events are missing, so this is not the complete schedule."
}

func (t *ListCalendarTool) parseMaxResults(args map[string]any) int {
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
	return maxResults
}

// ── ListTasksTool ──────────────────────────────────────────────────────────────

const listTasksToolName = "list_tasks"

// ListTasksTool fetches open Google Tasks and returns them as formatted Markdown.
type ListTasksTool struct {
	secretsRoot string
	tracer      *observability.DispatchTracer
}

func newListTasksTool(secretsRoot string, tracer *observability.DispatchTracer) *ListTasksTool {
	return &ListTasksTool{secretsRoot: secretsRoot, tracer: tracer}
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

func (t *ListTasksTool) Execute(ctx context.Context, _, _ string, args map[string]any) (string, error) {
	tasklistID := "@default"
	if v, ok := args["tasklist_id"]; ok {
		if s, _ := v.(string); s != "" {
			tasklistID = s
		}
	}

	var tasks []google.Task
	var err error
	if t.tracer != nil {
		err = t.tracer.TraceGoogleCall(ctx, "tasks", "ListTasks", func(ctx context.Context) error {
			var err2 error
			tasks, err2 = google.ListTasks(ctx, t.secretsRoot, tasklistID)
			if err2 != nil {
				return fmt.Errorf("list tasks: %w", err2)
			}
			return nil
		})
	} else {
		var err2 error
		tasks, err2 = google.ListTasks(ctx, t.secretsRoot, tasklistID)
		if err2 != nil {
			err = fmt.Errorf("list tasks: %w", err2)
		}
	}
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
	tracer      *observability.DispatchTracer
}

func newCreateTaskTool(secretsRoot string, tracer *observability.DispatchTracer) *CreateTaskTool {
	return &CreateTaskTool{secretsRoot: secretsRoot, tracer: tracer}
}

func (t *CreateTaskTool) Name() string { return createTaskToolName }

type createTaskArgs struct {
	Title      string `json:"title" schema:"The title of the task to create. Required."`
	Notes      string `json:"notes,omitempty" schema:"Optional notes or description to attach to the task."`
	TasklistID string `json:"tasklist_id,omitempty" schema:"The task list ID to add the task to. Defaults to \"@default\"."`
}

func (t *CreateTaskTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:          createTaskToolName,
		Description:   "Create a new task in Google Tasks. Returns a confirmation with the task title and its assigned ID.",
		SideEffecting: true,
		Parameters:    agent.DeriveSchema(createTaskArgs{}),
	}
}

func (t *CreateTaskTool) Execute(ctx context.Context, _, _ string, args map[string]any) (string, error) {
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

	var id string
	var err error
	if t.tracer != nil {
		err = t.tracer.TraceGoogleCall(ctx, "tasks", "CreateTask", func(ctx context.Context) error {
			var err2 error
			id, err2 = google.CreateTask(ctx, t.secretsRoot, tasklistID, title, notes)
			if err2 != nil {
				return fmt.Errorf("create task: %w", err2)
			}
			return nil
		})
	} else {
		var err2 error
		id, err2 = google.CreateTask(ctx, t.secretsRoot, tasklistID, title, notes)
		if err2 != nil {
			err = fmt.Errorf("create task: %w", err2)
		}
	}
	if err != nil {
		return "", fmt.Errorf("create_task: %w", err)
	}
	return fmt.Sprintf("Task created: %s (id: %s)", title, id), nil
}

// -- CompleteTaskTool -----------------------------------------------------------

const completeTaskToolName = "complete_task"

type CompleteTaskTool struct {
	secretsRoot string
	tracer      *observability.DispatchTracer
}

func newCompleteTaskTool(secretsRoot string, tracer *observability.DispatchTracer) *CompleteTaskTool {
	return &CompleteTaskTool{secretsRoot: secretsRoot, tracer: tracer}
}

func (t *CompleteTaskTool) Name() string { return completeTaskToolName }

type completeTaskArgs struct {
	TaskID     string `json:"task_id" schema:"The ID of the task to complete. Required."`
	TasklistID string `json:"tasklist_id,omitempty" schema:"The task list ID. Defaults to \"@default\"."`
}

func (t *CompleteTaskTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:          completeTaskToolName,
		Description:   "Mark a Google Task as completed. Use the task ID returned by list_tasks.",
		SideEffecting: true,
		Parameters:    agent.DeriveSchema(completeTaskArgs{}),
	}
}

func (t *CompleteTaskTool) Execute(ctx context.Context, _, _ string, args map[string]any) (string, error) {
	taskID, _ := args["task_id"].(string)
	if strings.TrimSpace(taskID) == "" {
		return "", fmt.Errorf("complete_task: task_id is required")
	}
	tasklistID, _ := args["tasklist_id"].(string)
	var err error
	if t.tracer != nil {
		err = t.tracer.TraceGoogleCall(ctx, "tasks", "CompleteTask", func(ctx context.Context) error {
			return google.CompleteTask(ctx, t.secretsRoot, tasklistID, taskID)
		})
	} else {
		err = google.CompleteTask(ctx, t.secretsRoot, tasklistID, taskID)
	}
	if err != nil {
		return "", fmt.Errorf("complete_task: %w", err)
	}
	return fmt.Sprintf("Task %s marked as completed.", taskID), nil
}

// -- UpdateTaskTool -------------------------------------------------------------

const updateTaskToolName = "update_task"

type UpdateTaskTool struct {
	secretsRoot string
	tracer      *observability.DispatchTracer
}

func newUpdateTaskTool(secretsRoot string, tracer *observability.DispatchTracer) *UpdateTaskTool {
	return &UpdateTaskTool{secretsRoot: secretsRoot, tracer: tracer}
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
		Name:          updateTaskToolName,
		Description:   "Update an existing Google Task's title, notes, or due date. Use the task ID returned by list_tasks. Only provide the fields you want to change.",
		SideEffecting: true,
		Parameters:    agent.DeriveSchema(updateTaskArgs{}),
	}
}

func (t *UpdateTaskTool) Execute(ctx context.Context, _, _ string, args map[string]any) (string, error) {
	taskID, _ := args["task_id"].(string)
	if strings.TrimSpace(taskID) == "" {
		return "", fmt.Errorf("update_task: task_id is required")
	}
	tasklistID, _ := args["tasklist_id"].(string)
	title, _ := args["title"].(string)
	notes, _ := args["notes"].(string)
	due, _ := args["due"].(string)

	var err error
	if t.tracer != nil {
		err = t.tracer.TraceGoogleCall(ctx, "tasks", "UpdateTask", func(ctx context.Context) error {
			return google.UpdateTask(ctx, t.secretsRoot, tasklistID, taskID, title, notes, due)
		})
	} else {
		err = google.UpdateTask(ctx, t.secretsRoot, tasklistID, taskID, title, notes, due)
	}
	if err != nil {
		return "", fmt.Errorf("update_task: %w", err)
	}
	return fmt.Sprintf("Task %s updated.", taskID), nil
}

// ── CreateCalendarEventTool ────────────────────────────────────────────────────

const createCalendarEventToolName = "create_calendar_event"

// CreateCalendarEventTool creates a new event in a Google Calendar.
type CreateCalendarEventTool struct {
	secretsRoot string
	tracer      *observability.DispatchTracer
}

func newCreateCalendarEventTool(secretsRoot string, tracer *observability.DispatchTracer) *CreateCalendarEventTool {
	return &CreateCalendarEventTool{secretsRoot: secretsRoot, tracer: tracer}
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
		Name:          createCalendarEventToolName,
		Description:   "Create a new event in a Google Calendar.",
		SideEffecting: true,
		Parameters:    agent.DeriveSchema(createCalendarEventArgs{}),
	}
}

func (t *CreateCalendarEventTool) Execute(ctx context.Context, _, _ string, args map[string]any) (string, error) {
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

	var id string
	var err error
	if t.tracer != nil {
		err = t.tracer.TraceGoogleCall(ctx, "calendar", "CreateEvent", func(ctx context.Context) error {
			var err2 error
			id, err2 = google.CreateEvent(ctx, t.secretsRoot, calendarID, summary, description, startTime, endTime, location)
			if err2 != nil {
				return fmt.Errorf("create event: %w", err2)
			}
			return nil
		})
	} else {
		var err2 error
		id, err2 = google.CreateEvent(ctx, t.secretsRoot, calendarID, summary, description, startTime, endTime, location)
		if err2 != nil {
			err = fmt.Errorf("create event: %w", err2)
		}
	}
	if err != nil {
		return "", fmt.Errorf("create_calendar_event: %w", err)
	}
	return fmt.Sprintf("Event created: %s (id: %s)", summary, id), nil
}

// ── WebSearchTool ─────────────────────────────────────────────────────────────

const webSearchToolName = "google_search"

// WebSearchTool performs a web search using Google Custom Search API.
type WebSearchTool struct {
	apiKey     string
	cx         string
	baseURL    string
	tracer     *observability.DispatchTracer
	httpClient *http.Client
}

func newWebSearchTool(apiKey, cx string, tracer *observability.DispatchTracer) *WebSearchTool {
	return &WebSearchTool{
		apiKey:  apiKey,
		cx:      cx,
		baseURL: google.DefaultBaseURL,
		tracer:  tracer,
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
	if t.httpClient != nil {
		svc.HTTPClient = t.httpClient
	}
	var results []google.SearchResult
	var err error
	if t.tracer != nil {
		err = t.tracer.TraceGoogleCall(ctx, "search", "Execute", func(ctx context.Context) error {
			var err2 error
			results, err2 = svc.Execute(ctx, t.apiKey, t.cx, query)
			if err2 != nil {
				return fmt.Errorf("search execute: %w", err2)
			}
			return nil
		})
	} else {
		var err2 error
		results, err2 = svc.Execute(ctx, t.apiKey, t.cx, query)
		if err2 != nil {
			err = fmt.Errorf("search execute: %w", err2)
		}
	}
	if err != nil {
		return "", fmt.Errorf("google_search: %w", err)
	}

	return google.FormatSearchMarkdown(results), nil
}
