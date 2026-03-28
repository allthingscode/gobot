package google

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestFormatTasksMarkdown_Empty(t *testing.T) {
	if got := FormatTasksMarkdown(nil); got != "" {
		t.Errorf("expected empty string for nil tasks, got %q", got)
	}
}

func TestFormatTasksMarkdown_Basic(t *testing.T) {
	tasks := []Task{
		{Title: "File taxes", Due: "2026-04-15T00:00:00.000Z"},
		{Title: "Call dentist"},
	}
	out := FormatTasksMarkdown(tasks)
	if !strings.Contains(out, "File taxes") {
		t.Errorf("expected 'File taxes' in output:\n%s", out)
	}
	if !strings.Contains(out, "2026-04-15") {
		t.Errorf("expected due date in output:\n%s", out)
	}
	if !strings.Contains(out, "Call dentist") {
		t.Errorf("expected 'Call dentist' in output:\n%s", out)
	}
	if !strings.Contains(out, "✅") {
		t.Errorf("expected tasks emoji in output:\n%s", out)
	}
}

func TestFormatTasksMarkdown_NoTitle(t *testing.T) {
	tasks := []Task{{Status: "needsAction"}}
	out := FormatTasksMarkdown(tasks)
	if !strings.Contains(out, "(untitled)") {
		t.Errorf("expected '(untitled)' placeholder:\n%s", out)
	}
}

func TestListTasksWithClient(t *testing.T) {
	cases := []struct {
		name      string
		items     []map[string]any
		wantCount int
		wantTitle string
	}{
		{
			name: "filters completed tasks",
			items: []map[string]any{
				{"id": "1", "title": "Buy milk", "status": "needsAction"},
				{"id": "2", "title": "Done task", "status": "completed"},
			},
			wantCount: 1,
			wantTitle: "Buy milk",
		},
		{
			name:      "empty list",
			items:     []map[string]any{},
			wantCount: 0,
		},
		{
			name: "preserves due date",
			items: []map[string]any{
				{"id": "3", "title": "File taxes", "status": "needsAction", "due": "2026-04-15T00:00:00.000Z"},
			},
			wantCount: 1,
			wantTitle: "File taxes",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				json.NewEncoder(w).Encode(map[string]any{"items": tc.items})
			}))
			defer srv.Close()

			dir := t.TempDir()
			writeToken(t, dir, storedToken{
				Token:  "access",
				Expiry: time.Now().Add(1 * time.Hour),
			})

			client := redirectClient(tasksBaseURL, srv.URL)
			tasks, err := listTasksWithClient(dir, "@default", client)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(tasks) != tc.wantCount {
				t.Fatalf("want %d tasks, got %d", tc.wantCount, len(tasks))
			}
			if tc.wantCount > 0 && tasks[0].Title != tc.wantTitle {
				t.Errorf("want title %q, got %q", tc.wantTitle, tasks[0].Title)
			}
		})
	}
}

func TestListTasksWithClient_AuthError(t *testing.T) {
	_, err := listTasksWithClient(t.TempDir(), "@default", http.DefaultClient)
	if err == nil {
		t.Fatal("expected error for missing token file")
	}
}

func TestCreateTaskWithClient_Success(t *testing.T) {
	var receivedTitle string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]string
		json.NewDecoder(r.Body).Decode(&body)
		receivedTitle = body["title"]
		json.NewEncoder(w).Encode(map[string]string{"id": "new-id-123"})
	}))
	defer srv.Close()

	dir := t.TempDir()
	writeToken(t, dir, storedToken{
		Token:  "access",
		Expiry: time.Now().Add(1 * time.Hour),
	})

	client := redirectClient(tasksBaseURL, srv.URL)
	id, err := createTaskWithClient(dir, "@default", "Test task", "", client)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if id != "new-id-123" {
		t.Errorf("want new-id-123, got %q", id)
	}
	if receivedTitle != "Test task" {
		t.Errorf("want title 'Test task' in request body, got %q", receivedTitle)
	}
}

func TestCreateTaskWithClient_AuthError(t *testing.T) {
	_, err := createTaskWithClient(t.TempDir(), "@default", "title", "", http.DefaultClient)
	if err == nil {
		t.Fatal("expected error for missing token file")
	}
}

func TestFormatDueDate(t *testing.T) {
	cases := []struct{ in, want string }{
		{"2026-04-15T00:00:00.000Z", "2026-04-15"},
		{"2026-04-15", "2026-04-15"},
		{"", ""},
		{"2026", "2026"},
	}
	for _, tc := range cases {
		got := formatDueDate(tc.in)
		if got != tc.want {
			t.Errorf("formatDueDate(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}
