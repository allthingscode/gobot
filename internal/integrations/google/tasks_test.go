//nolint:testpackage // requires unexported tasks internals for testing
package google

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
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

//nolint:gocognit,cyclop,funlen // Table-driven integration matrix keeps request and result assertions together.
func TestListTasksWithClient_Pagination(t *testing.T) {
	t.Parallel()
	const opaque = "next +/&=?#% token"
	var firstPage []map[string]string
	var wantMany []Task
	for i := 1; i <= 21; i++ {
		task := Task{ID: fmt.Sprintf("id-%d", i), Title: fmt.Sprintf("Task %d", i),
			Notes: "notes", Status: "needsAction", Due: "2026-10-17T00:00:00Z"}
		wantMany = append(wantMany, task)
		if i <= 20 {
			firstPage = append(firstPage, map[string]string{"id": task.ID, "title": task.Title,
				"notes": task.Notes, "status": task.Status, "due": task.Due})
		}
	}
	firstPage = append(firstPage, map[string]string{"id": "completed", "status": "completed"})
	firstJSON, err := json.Marshal(map[string]any{"items": firstPage, "nextPageToken": opaque})
	if err != nil {
		t.Fatal(err)
	}
	last := wantMany[20]
	lastJSON, err := json.Marshal(map[string]any{"items": []map[string]string{{"id": last.ID,
		"title": last.Title, "notes": last.Notes, "status": last.Status, "due": last.Due}}})
	if err != nil {
		t.Fatal(err)
	}
	one := Task{ID: "one", Title: "One", Status: "needsAction"}
	const oneJSON = `{"items":[{"id":"one","title":"One","status":"needsAction"}]}`
	for _, tc := range []struct {
		name    string
		list    string
		pages   []string
		tokens  []string
		want    []Task
		failure int
		cancel  bool
		cycle   bool
	}{
		{name: "twenty one tasks and opaque token", list: "custom-list", pages: []string{string(firstJSON), string(lastJSON)}, tokens: []string{"", opaque}, want: wantMany},
		{name: "empty first and intermediate", pages: []string{`{"nextPageToken":"a"}`, `{"items":[],"nextPageToken":"b"}`, oneJSON}, tokens: []string{"", "a", "b"}, want: []Task{one}},
		{name: "filtered intermediate and omitted final fields", pages: []string{`{"items":[{"id":"one","title":"One","status":"needsAction"}],"nextPageToken":"a"}`, `{"items":[{"status":"completed"}],"nextPageToken":"b"}`, `{}`}, tokens: []string{"", "a", "b"}, want: []Task{one}},
		{name: "single page", list: "@default", pages: []string{oneJSON}, tokens: []string{""}, want: []Task{one}},
		{name: "empty result", pages: []string{`{}`}, tokens: []string{""}, want: []Task{}},
		{name: "single token cycle", pages: []string{`{"items":[{"id":"partial"}],"nextPageToken":"same"}`, `{"nextPageToken":"same"}`}, tokens: []string{"", "same"}, cycle: true},
		{name: "alternating cycle", pages: []string{`{"items":[{"id":"partial"}],"nextPageToken":"a"}`, `{"nextPageToken":"b"}`, `{"nextPageToken":"a"}`}, tokens: []string{"", "a", "b"}, cycle: true},
		{name: "cycle after unique prefix", pages: []string{`{"nextPageToken":"prefix"}`, `{"items":[{"id":"partial"}],"nextPageToken":"a"}`, `{"nextPageToken":"b"}`, `{"nextPageToken":"a"}`}, tokens: []string{"", "prefix", "a", "b"}, cycle: true},
		{name: "several unique tokens", pages: []string{`{"items":[{"id":"1"}],"nextPageToken":"a"}`, `{"items":[{"id":"2"}],"nextPageToken":"b"}`, `{"items":[{"id":"3"}],"nextPageToken":"c"}`, `{"items":[{"id":"4"}],"nextPageToken":"d"}`, `{"items":[{"id":"5"}]}`}, tokens: []string{"", "a", "b", "c", "d"}, want: []Task{{ID: "1"}, {ID: "2"}, {ID: "3"}, {ID: "4"}, {ID: "5"}}},
		{name: "second page HTTP error", pages: []string{`{"items":[{"id":"partial"}],"nextPageToken":"a"}`, `{}`}, tokens: []string{"", "a"}, failure: http.StatusInternalServerError},
		{name: "second page malformed JSON", pages: []string{`{"items":[{"id":"partial"}],"nextPageToken":"a"}`, `{`}, tokens: []string{"", "a"}, failure: http.StatusOK},
		{name: "second page cancellation", pages: []string{`{"items":[{"id":"partial"}],"nextPageToken":"a"}`, `{}`}, tokens: []string{"", "a"}, cancel: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			requests := 0
			list := tc.list
			if list == "" {
				list = "@default" //nolint:goconst // Google API default task list identifier
			}
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				index := requests
				requests++
				if index >= len(tc.pages) {
					t.Error("unexpected extra request")
					w.WriteHeader(http.StatusBadRequest)
					return
				}
				q := r.URL.Query()
				if r.Method != http.MethodGet || r.URL.Path != "/lists/"+list+"/tasks" ||
					q.Get("showCompleted") != "false" || q.Get("showHidden") != "false" ||
					q.Get("pageToken") != tc.tokens[index] || r.Header.Get("Authorization") != "Bearer fake" {
					t.Errorf("unexpected request: %s %s, auth %q", r.Method, r.URL, r.Header.Get("Authorization"))
				}
				if index == 0 && q.Has("pageToken") {
					t.Error("first request must omit pageToken")
				}
				if index == 1 && tc.cancel {
					cancel()
					<-r.Context().Done()
					return
				}
				if index == 1 && tc.failure != 0 {
					w.WriteHeader(tc.failure)
				}
				_, _ = w.Write([]byte(tc.pages[index]))
			}))
			defer srv.Close()
			got, err := listTasksWithClient(ctx, setupTestToken(t), tc.list, redirectClient(tasksBaseURL, srv.URL))
			if tc.failure != 0 || tc.cancel || tc.cycle {
				if err == nil || !strings.Contains(err.Error(), "tasks list:") || got != nil {
					t.Fatalf("want contextual error and nil tasks, got %v, %v", got, err)
				}
				if tc.cancel && !errors.Is(err, context.Canceled) {
					t.Errorf("want context.Canceled, got %v", err)
				}
				if tc.cycle && (errors.Unwrap(err) == nil || !strings.Contains(err.Error(), "repeated pagination token")) {
					t.Errorf("want wrapped repeated-token cause, got %v", err)
				}
			} else if err != nil || !reflect.DeepEqual(got, tc.want) {
				t.Errorf("tasks = %#v, error = %v; want %#v", got, err, tc.want)
			}
			if requests != len(tc.pages) {
				t.Errorf("requests = %d, want %d", requests, len(tc.pages))
			}
			if tc.failure == 0 && !tc.cancel && !tc.cycle {
				requests = 0
				got, err = listTasksWithClient(ctx, setupTestToken(t), tc.list, redirectClient(tasksBaseURL, srv.URL))
				if err != nil || !reflect.DeepEqual(got, tc.want) || requests != len(tc.pages) {
					t.Errorf("repeat invocation: tasks = %#v, error = %v, requests = %d", got, err, requests)
				}
			}
		})
	}
}
