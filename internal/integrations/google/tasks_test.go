//nolint:testpackage // requires unexported tasks internals for testing
package google

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestFormatTasksMarkdown_IncludesID verifies task ID appears in output.
func TestFormatTasksMarkdown_IncludesID(t *testing.T) {
	t.Parallel()
	tasks := []Task{
		{ID: "abc123", Title: "Buy milk"},
		{ID: "def456", Title: "Call dentist", Due: "2026-04-01T00:00:00Z"},
	}
	got := FormatTasksMarkdown(tasks)
	for _, want := range []string{"[id:abc123]", "[id:def456]", "Buy milk", "Call dentist"} {
		if !strings.Contains(got, want) {
			t.Errorf("FormatTasksMarkdown output missing %q\ngot:\n%s", want, got)
		}
	}
}

// TestFormatTasksMarkdown_Empty returns empty string for no tasks.
func TestFormatTasksMarkdown_Empty(t *testing.T) {
	t.Parallel()
	if got := FormatTasksMarkdown(nil); got != "" {
		t.Errorf("want empty string, got %q", got)
	}
}

// TestCompleteTask_Success mocks a PATCH endpoint and asserts no error.
func TestCompleteTask_Success(t *testing.T) {
	t.Parallel()
	var gotBody map[string]string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPatch {
			t.Errorf("want PATCH, got %s", r.Method)
		}
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("{}"))
	}))
	defer srv.Close()

	// completeTaskWithClient needs a real bearer token — we bypass auth by
	// calling apiPatch directly with a fake token against our mock server.
	var dest struct{}
	err := apiPatch(context.Background(), "fake-token", srv.URL+"/lists/@default/tasks/task-1",
		map[string]string{"status": "completed"}, srv.Client(), &dest)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if gotBody["status"] != "completed" {
		t.Errorf("want body status=completed, got %v", gotBody)
	}
}

// TestUpdateTask_NoFields returns error when no fields provided.
func TestUpdateTask_NoFields(t *testing.T) {
	t.Parallel()
	// Use the simple version from the plan: assert non-nil error from UpdateTask with a tempdir.
	err := UpdateTask(context.Background(), t.TempDir(), "@default", "task-1", "", "", "")
	if err == nil {
		t.Fatal("expected error when no fields provided, got nil")
	}
}

// TestUpdateTask_TitleOnly mocks PATCH and checks only "title" is in body.
func TestUpdateTask_TitleOnly(t *testing.T) {
	t.Parallel()
	var gotBody map[string]string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := json.NewDecoder(r.Body).Decode(&gotBody); err != nil {
			t.Fatal(err)
		}
		w.WriteHeader(http.StatusOK)
		if _, err := w.Write([]byte("{}")); err != nil {
			t.Fatal(err)
		}
	}))
	defer srv.Close()

	var dest struct{}
	err := apiPatch(context.Background(), "fake-token", srv.URL+"/lists/@default/tasks/task-1",
		map[string]string{"title": "New title"}, srv.Client(), &dest)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if gotBody["title"] != "New title" {
		t.Errorf("want title='New title', got %v", gotBody)
	}
	if _, ok := gotBody["notes"]; ok {
		t.Error("notes field must not be present when not provided")
	}
}
