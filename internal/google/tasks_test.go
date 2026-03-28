package google

import (
	"strings"
	"testing"
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
