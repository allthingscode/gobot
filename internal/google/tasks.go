package google

import (
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
func ListTasks(secretsRoot string, tasklistID string) ([]Task, error) {
	return listTasksWithClient(secretsRoot, tasklistID, http.DefaultClient)
}

func listTasksWithClient(secretsRoot, tasklistID string, client *http.Client) ([]Task, error) {
	token, err := bearerTokenWithClient(secretsRoot, client)
	if err != nil {
		return nil, fmt.Errorf("tasks auth: %w", err)
	}

	if tasklistID == "" {
		tasklistID = "@default"
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

	if err := apiGet(token, apiURL, client, &resp); err != nil {
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
func CreateTask(secretsRoot, tasklistID, title, notes string) (string, error) {
	return createTaskWithClient(secretsRoot, tasklistID, title, notes, http.DefaultClient)
}

func createTaskWithClient(secretsRoot, tasklistID, title, notes string, client *http.Client) (string, error) {
	token, err := bearerTokenWithClient(secretsRoot, client)
	if err != nil {
		return "", fmt.Errorf("tasks auth: %w", err)
	}

	if tasklistID == "" {
		tasklistID = "@default"
	}

	apiURL := fmt.Sprintf("%s/lists/%s/tasks", tasksBaseURL, tasklistID)
	body := map[string]string{"title": title}
	if notes != "" {
		body["notes"] = notes
	}

	var created struct {
		ID string `json:"id"`
	}
	if err := apiPost(token, apiURL, body, client, &created); err != nil {
		return "", fmt.Errorf("tasks create: %w", err)
	}
	return created.ID, nil
}

// FormatTasksMarkdown returns a Markdown bullet list of open tasks for use in
// the system prompt. Returns empty string when tasks is empty.
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
			sb.WriteString(fmt.Sprintf("- [ ] %s _(due %s)_\n", title, formatDueDate(task.Due)))
		} else {
			sb.WriteString(fmt.Sprintf("- [ ] %s\n", title))
		}
	}
	return sb.String()
}

// formatDueDate trims a Google Tasks due date (RFC3339) to a short date string.
func formatDueDate(s string) string {
	if len(s) >= 10 {
		return s[:10]
	}
	return s
}
