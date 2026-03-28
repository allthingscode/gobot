package main

import (
	"context"
	"testing"

	"google.golang.org/genai"
)

// ── helpers ───────────────────────────────────────────────────────────────────

// requiredSet converts a slice of required param names into a lookup map.
func requiredSet(required []string) map[string]bool {
	m := make(map[string]bool, len(required))
	for _, r := range required {
		m[r] = true
	}
	return m
}

// assertDeclaration verifies common FunctionDeclaration invariants.
func assertDeclaration(t *testing.T, decl *genai.FunctionDeclaration, wantName string, wantRequired []string) {
	t.Helper()
	if decl == nil {
		t.Fatal("Declaration() returned nil")
	}
	if decl.Name != wantName {
		t.Errorf("Declaration.Name = %q, want %q", decl.Name, wantName)
	}
	if decl.Description == "" {
		t.Error("Declaration.Description must not be empty")
	}
	if decl.Parameters == nil {
		t.Fatal("Declaration.Parameters is nil")
	}
	rs := requiredSet(decl.Parameters.Required)
	for _, req := range wantRequired {
		if _, ok := decl.Parameters.Properties[req]; !ok {
			t.Errorf("Parameters.Properties missing %q", req)
		}
		if !rs[req] {
			t.Errorf("Parameters.Required missing %q", req)
		}
	}
}

// ── ListCalendarTool ──────────────────────────────────────────────────────────

func TestListCalendarTool_Name(t *testing.T) {
	tool := newListCalendarTool("/tmp/secrets")
	if tool.Name() != listCalendarToolName {
		t.Errorf("Name() = %q, want %q", tool.Name(), listCalendarToolName)
	}
}

func TestListCalendarTool_Declaration(t *testing.T) {
	tool := newListCalendarTool("/tmp/secrets")
	decl := tool.Declaration()
	assertDeclaration(t, decl, listCalendarToolName, []string{})

	// Both optional params must be declared in Properties.
	for _, param := range []string{"days_ahead", "max_results"} {
		if _, ok := decl.Parameters.Properties[param]; !ok {
			t.Errorf("Parameters.Properties missing optional param %q", param)
		}
	}
	if decl.Parameters.Properties["days_ahead"].Type != genai.TypeInteger {
		t.Errorf("days_ahead type = %v, want TypeInteger", decl.Parameters.Properties["days_ahead"].Type)
	}
	if decl.Parameters.Properties["max_results"].Type != genai.TypeInteger {
		t.Errorf("max_results type = %v, want TypeInteger", decl.Parameters.Properties["max_results"].Type)
	}
}

func TestListCalendarTool_Execute_BadSecretsRoot(t *testing.T) {
	// No live network call expected to succeed; we verify that Execute attempts
	// the API call (not short-circuited) and propagates the auth/network error.
	tool := newListCalendarTool("/nonexistent/secrets/root")
	_, err := tool.Execute(context.Background(), "test-session", map[string]any{
		"max_results": float64(5),
	})
	if err == nil {
		t.Fatal("Execute() with bad secretsRoot expected an error, got nil")
	}
}

func TestListCalendarTool_Execute_DefaultMaxResults(t *testing.T) {
	// Passing no args at all must not panic; the call will fail at auth.
	tool := newListCalendarTool("/nonexistent/secrets/root")
	_, err := tool.Execute(context.Background(), "test-session", map[string]any{})
	if err == nil {
		t.Fatal("Execute() with bad secretsRoot expected an error, got nil")
	}
	// Error must be wrapped under the tool name.
	if !contains(err.Error(), "list_calendar_events") {
		t.Errorf("error %q does not contain tool name", err.Error())
	}
}

// ── ListTasksTool ─────────────────────────────────────────────────────────────

func TestListTasksTool_Name(t *testing.T) {
	tool := newListTasksTool("/tmp/secrets")
	if tool.Name() != listTasksToolName {
		t.Errorf("Name() = %q, want %q", tool.Name(), listTasksToolName)
	}
}

func TestListTasksTool_Declaration(t *testing.T) {
	tool := newListTasksTool("/tmp/secrets")
	decl := tool.Declaration()
	assertDeclaration(t, decl, listTasksToolName, []string{})

	if _, ok := decl.Parameters.Properties["tasklist_id"]; !ok {
		t.Error("Parameters.Properties missing optional param \"tasklist_id\"")
	}
	if decl.Parameters.Properties["tasklist_id"].Type != genai.TypeString {
		t.Errorf("tasklist_id type = %v, want TypeString", decl.Parameters.Properties["tasklist_id"].Type)
	}
}

func TestListTasksTool_Execute_BadSecretsRoot(t *testing.T) {
	tool := newListTasksTool("/nonexistent/secrets/root")
	_, err := tool.Execute(context.Background(), "test-session", map[string]any{})
	if err == nil {
		t.Fatal("Execute() with bad secretsRoot expected an error, got nil")
	}
	if !contains(err.Error(), "list_tasks") {
		t.Errorf("error %q does not contain tool name", err.Error())
	}
}

func TestListTasksTool_Execute_CustomTasklistID(t *testing.T) {
	// Providing a custom tasklist_id should not cause a panic; the call will
	// fail at auth, confirming arg handling ran correctly.
	tool := newListTasksTool("/nonexistent/secrets/root")
	_, err := tool.Execute(context.Background(), "test-session", map[string]any{
		"tasklist_id": "MTIzNDU2Nzg5",
	})
	if err == nil {
		t.Fatal("Execute() with bad secretsRoot expected an error, got nil")
	}
}

// ── CreateTaskTool ────────────────────────────────────────────────────────────

func TestCreateTaskTool_Name(t *testing.T) {
	tool := newCreateTaskTool("/tmp/secrets")
	if tool.Name() != createTaskToolName {
		t.Errorf("Name() = %q, want %q", tool.Name(), createTaskToolName)
	}
}

func TestCreateTaskTool_Declaration(t *testing.T) {
	tool := newCreateTaskTool("/tmp/secrets")
	decl := tool.Declaration()
	assertDeclaration(t, decl, createTaskToolName, []string{"title"})

	for _, param := range []string{"title", "notes", "tasklist_id"} {
		if _, ok := decl.Parameters.Properties[param]; !ok {
			t.Errorf("Parameters.Properties missing param %q", param)
		}
	}
	if decl.Parameters.Properties["title"].Type != genai.TypeString {
		t.Errorf("title type = %v, want TypeString", decl.Parameters.Properties["title"].Type)
	}
	if decl.Parameters.Properties["notes"].Type != genai.TypeString {
		t.Errorf("notes type = %v, want TypeString", decl.Parameters.Properties["notes"].Type)
	}
	if decl.Parameters.Properties["tasklist_id"].Type != genai.TypeString {
		t.Errorf("tasklist_id type = %v, want TypeString", decl.Parameters.Properties["tasklist_id"].Type)
	}
}

func TestCreateTaskTool_Execute(t *testing.T) {
	tests := []struct {
		name          string
		args          map[string]any
		wantErr       bool
		wantErrSubstr string
	}{
		{
			name:          "missing title returns error immediately",
			args:          map[string]any{},
			wantErr:       true,
			wantErrSubstr: "title is required",
		},
		{
			name:          "empty string title returns error immediately",
			args:          map[string]any{"title": ""},
			wantErr:       true,
			wantErrSubstr: "title is required",
		},
		{
			name:          "whitespace-only title returns error immediately",
			args:          map[string]any{"title": "   "},
			wantErr:       true,
			wantErrSubstr: "title is required",
		},
		{
			name: "valid title with bad secretsRoot reaches API and returns error",
			args: map[string]any{
				"title": "Buy milk",
				"notes": "Whole milk please",
			},
			wantErr:       true,
			wantErrSubstr: "create_task",
		},
		{
			name: "valid title with custom tasklist_id with bad secretsRoot reaches API",
			args: map[string]any{
				"title":       "Quarterly review",
				"tasklist_id": "MTIzNDU2Nzg5",
			},
			wantErr:       true,
			wantErrSubstr: "create_task",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			tool := newCreateTaskTool("/nonexistent/secrets/root")
			result, err := tool.Execute(context.Background(), "test-session", tc.args)

			if tc.wantErr {
				if err == nil {
					t.Fatalf("Execute() expected error, got result %q", result)
				}
				if tc.wantErrSubstr != "" && !contains(err.Error(), tc.wantErrSubstr) {
					t.Errorf("error %q does not contain %q", err.Error(), tc.wantErrSubstr)
				}
				return
			}
			if err != nil {
				t.Fatalf("Execute() unexpected error: %v", err)
			}
		})
	}
}
