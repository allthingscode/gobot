package google

import (
	"context"
	"fmt"
	"net/http"
	"strings"
)

const tasksBaseURL = "https://tasks.googleapis.com/tasks/v1"

// Task is a simplified view of a Google Tasks item.
type Task struct {
	ID     string
	Title  string
	Notes  string
	Status string // "needsAction" or "completed"
	Due    string // RFC3339 date string, may be empty
}

// ListTasks returns incomplete tasks from the given task list.
// Pass "@default" for tasklistID to use the default list.
func ListTasks(ctx context.Context, secretsRoot, tasklistID string) ([]Task, error) {
	return listTasksWithClient(ctx, secretsRoot, tasklistID, TimeoutClient)
}

func listTasksWithClient(ctx context.Context, secretsRoot, tasklistID string, client *http.Client) ([]Task, error) {
	token, err := bearerTokenWithClient(ctx, secretsRoot, client)
	if err != nil {
		return nil, fmt.Errorf("tasks auth: %w", err)
	}

	if tasklistID == "" {
		tasklistID = "@default" //nolint:goconst // Google API default task list identifier
	}

	apiURL := fmt.Sprintf("%s/lists/%s/tasks?showCompleted=false&showHidden=false",
		tasksBaseURL, tasklistID)

	var resp struct {
		Items []struct {
			ID     string `json:"id"`
			Title  string `json:"title"`
			Notes  string `json:"notes"`
			Status string `json:"status"`
			Due    string `json:"due"`
		} `json:"items"`
	}

	if err := apiGet(ctx, token, apiURL, client, &resp); err != nil {
		return nil, fmt.Errorf("tasks list: %w", err)
	}

	tasks := make([]Task, 0, len(resp.Items))
	for _, item := range resp.Items {
		if item.Status == "completed" {
			continue
		}
		tasks = append(tasks, Task{
			ID:     item.ID,
			Title:  item.Title,
			Notes:  item.Notes,
			Status: item.Status,
			Due:    item.Due,
		})
	}
	return tasks, nil
}

// CreateTask creates a new task in the specified task list and returns the
// created task's ID.
func CreateTask(ctx context.Context, secretsRoot, tasklistID, title, notes string) (string, error) {
	return createTaskWithClient(ctx, secretsRoot, tasklistID, title, notes, TimeoutClient)
}

func createTaskWithClient(ctx context.Context, secretsRoot, tasklistID, title, notes string, client *http.Client) (string, error) {
	token, err := bearerTokenWithClient(ctx, secretsRoot, client)
	if err != nil {
		return "", fmt.Errorf("tasks auth: %w", err)
	}

	if tasklistID == "" {
		tasklistID = "@default" //nolint:goconst // Google API default task list identifier
	}

	apiURL := fmt.Sprintf("%s/lists/%s/tasks", tasksBaseURL, tasklistID)
	body := map[string]string{"title": title}
	if notes != "" {
		body["notes"] = notes
	}

	var created struct {
		ID string `json:"id"`
	}
	if err := apiPost(ctx, token, apiURL, body, client, &created); err != nil {
		return "", fmt.Errorf("tasks create: %w", err)
	}
	return created.ID, nil
}

// FormatTasksMarkdown returns a Markdown bullet list of open tasks for use in
// the system prompt. Returns empty string when tasks is empty.
// Task IDs are included so the agent can reference them in complete_task / update_task.
func FormatTasksMarkdown(tasks []Task) string {
	if len(tasks) == 0 {
		return ""
	}
	var sb strings.Builder
	sb.WriteString("### ✅ Open Tasks\n")
	for _, task := range tasks {
		title := task.Title
		if title == "" {
			title = "(untitled)"
		}
		if task.Due != "" {
			fmt.Fprintf(&sb, "- [ ] %s _(due %s)_ [id:%s]\n", title, formatDueDate(task.Due), task.ID)
		} else {
			fmt.Fprintf(&sb, "- [ ] %s [id:%s]\n", title, task.ID)
		}
	}
	return sb.String()
}

// CompleteTask marks a task as completed.
// tasklistID defaults to "@default" if empty.
func CompleteTask(ctx context.Context, secretsRoot, tasklistID, taskID string) error {
	return completeTaskWithClient(ctx, secretsRoot, tasklistID, taskID, TimeoutClient)
}

func completeTaskWithClient(ctx context.Context, secretsRoot, tasklistID, taskID string, client *http.Client) error {
	token, err := bearerTokenWithClient(ctx, secretsRoot, client)
	if err != nil {
		return fmt.Errorf("tasks auth: %w", err)
	}
	if tasklistID == "" {
		tasklistID = "@default" //nolint:goconst // Google API default task list identifier
	}
	apiURL := fmt.Sprintf("%s/lists/%s/tasks/%s", tasksBaseURL, tasklistID, taskID)
	var updated struct{}
	return apiPatch(ctx, token, apiURL, map[string]string{"status": "completed"}, client, &updated)
}

// UpdateTask modifies the title, notes, and/or due date of an existing task.
// Pass empty string for any field you do not want to change.
// tasklistID defaults to "@default" if empty.
// Returns an error if no fields are provided.
func UpdateTask(ctx context.Context, secretsRoot, tasklistID, taskID, title, notes, due string) error {
	return updateTaskWithClient(ctx, secretsRoot, tasklistID, taskID, title, notes, due, TimeoutClient)
}

func updateTaskWithClient(ctx context.Context, secretsRoot, tasklistID, taskID, title, notes, due string, client *http.Client) error {
	token, err := bearerTokenWithClient(ctx, secretsRoot, client)
	if err != nil {
		return fmt.Errorf("tasks auth: %w", err)
	}
	if tasklistID == "" {
		tasklistID = "@default" //nolint:goconst // Google API default task list identifier
	}
	body := map[string]string{}
	if title != "" {
		body["title"] = title
	}
	if notes != "" {
		body["notes"] = notes
	}
	if due != "" {
		body["due"] = due
	}
	if len(body) == 0 {
		return fmt.Errorf("update_task: at least one field (title, notes, due) must be provided")
	}
	apiURL := fmt.Sprintf("%s/lists/%s/tasks/%s", tasksBaseURL, tasklistID, taskID)
	var updated struct{}
	return apiPatch(ctx, token, apiURL, body, client, &updated)
}

// formatDueDate trims a Google Tasks due date (RFC3339) to a short date string.
func formatDueDate(s string) string {
	if len(s) >= 10 {
		return s[:10]
	}
	return s
}
