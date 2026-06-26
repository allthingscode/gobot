//nolint:testpackage // requires unexported mock types for testing
package agent

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	agentctx "github.com/allthingscode/gobot/internal/context"
)

func strPtr(s string) *string { return &s }

func TestMarkdownLogger_WritesFile(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	l := NewMarkdownLogger(root)
	msgs := []agentctx.StrategicMessage{
		{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: strPtr("hello")}},
		{Role: agentctx.RoleAssistant, Content: &agentctx.MessageContent{Str: strPtr("hi there")}},
	}
	if err := l.Log("session123", 1, msgs); err != nil {
		t.Fatalf("Log: %v", err)
	}
	date := time.Now().UTC().Format("2006-01-02")
	dir := filepath.Join(root, "workspace", "sessions", date)
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("expected 1 file, got %d", len(entries))
	}
	data, err := os.ReadFile(filepath.Join(dir, entries[0].Name()))
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	content := string(data)
	for _, want := range []string{"# Session: session123", "**Iteration:** 1", "## user", "hello", "## assistant", "hi there"} {
		if !strings.Contains(content, want) {
			t.Errorf("missing %q in output:\n%s", want, content)
		}
	}
}

func TestMarkdownLogger_SanitizesKey(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	l := NewMarkdownLogger(root)
	msgs := []agentctx.StrategicMessage{
		{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: strPtr("test")}},
	}
	if err := l.Log("123:456/789", 1, msgs); err != nil {
		t.Fatalf("Log: %v", err)
	}
	date := time.Now().UTC().Format("2006-01-02")
	dir := filepath.Join(root, "workspace", "sessions", date)
	entries, _ := os.ReadDir(dir)
	if len(entries) != 1 {
		t.Fatalf("expected 1 file, got %d", len(entries))
	}
	name := entries[0].Name()
	if strings.ContainsAny(name, ":/") {
		t.Errorf("filename still has unsafe chars: %s", name)
	}
}

func TestMarkdownLogger_CreatesDateDir(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	l := NewMarkdownLogger(root)
	msgs := []agentctx.StrategicMessage{{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: strPtr("a")}}}
	if err := l.Log("s1", 1, msgs); err != nil {
		t.Fatal(err)
	}
	if err := l.Log("s2", 1, msgs); err != nil {
		t.Fatal(err)
	}
	date := time.Now().UTC().Format("2006-01-02")
	entries, _ := os.ReadDir(filepath.Join(root, "workspace", "sessions", date))
	if len(entries) < 2 {
		t.Errorf("expected >=2 files, got %d", len(entries))
	}
}

func TestRenderMarkdown_ContentItems(t *testing.T) {
	t.Parallel()
	msgs := []agentctx.StrategicMessage{
		{Role: agentctx.RoleAssistant, Content: &agentctx.MessageContent{Items: []agentctx.ContentItem{
			{Tool: &agentctx.ToolCallContent{Type: "tool_call", ID: "id1", Function: agentctx.ToolCallFunction{Name: "search", Arguments: `{"q":"foo"}`}}},
			{Thinking: &agentctx.ThinkingContent{Type: "thinking", Text: "reasoning..."}},
		}}},
	}
	out := renderMarkdown("s", 2, msgs, time.Now().UTC())
	if !strings.Contains(out, "tool_call: search") {
		t.Errorf("expected tool_call in output:\n%s", out)
	}
	if !strings.Contains(out, "thinking: reasoning...") {
		t.Errorf("expected thinking in output:\n%s", out)
	}
}

func TestMarkdownLogger_PrunesOldDatedDirs(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	l := NewMarkdownLogger(root)
	sessionsDir := filepath.Join(root, "workspace", "sessions")

	now := time.Now().UTC()
	oldDir := filepath.Join(sessionsDir, "2000-01-01")
	// Strictly older than the window (older than maxSessionAgeDays ago).
	staleDir := filepath.Join(sessionsDir, now.AddDate(0, 0, -(maxSessionAgeDays+1)).Format("2006-01-02"))
	for _, d := range []string{oldDir, staleDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatalf("MkdirAll %s: %v", d, err)
		}
	}

	msgs := []agentctx.StrategicMessage{{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: strPtr("x")}}}
	if err := l.Log("s1", 1, msgs); err != nil {
		t.Fatalf("Log: %v", err)
	}

	for _, d := range []string{oldDir, staleDir} {
		if _, err := os.Stat(d); !os.IsNotExist(err) {
			t.Errorf("expected %s to be pruned, stat err = %v", d, err)
		}
	}
}

func TestMarkdownLogger_KeepsRecentDatedDirs(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	l := NewMarkdownLogger(root)
	sessionsDir := filepath.Join(root, "workspace", "sessions")

	now := time.Now().UTC()
	yesterday := filepath.Join(sessionsDir, now.AddDate(0, 0, -1).Format("2006-01-02"))
	// Exactly at the window edge (cutoff is exclusive: only strictly older is pruned).
	edge := filepath.Join(sessionsDir, now.AddDate(0, 0, -maxSessionAgeDays).Format("2006-01-02"))
	for _, d := range []string{yesterday, edge} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatalf("MkdirAll %s: %v", d, err)
		}
	}

	msgs := []agentctx.StrategicMessage{{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: strPtr("x")}}}
	if err := l.Log("s1", 1, msgs); err != nil {
		t.Fatalf("Log: %v", err)
	}

	for _, d := range []string{yesterday, edge} {
		if _, err := os.Stat(d); err != nil {
			t.Errorf("expected %s to be kept, stat err = %v", d, err)
		}
	}
	// The just-written turn's directory must always survive.
	today := filepath.Join(sessionsDir, now.Format("2006-01-02"))
	if _, err := os.Stat(today); err != nil {
		t.Errorf("today's transcript dir missing after Log: %v", err)
	}
}

func TestMarkdownLogger_IgnoresNonDateEntries(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	l := NewMarkdownLogger(root)
	sessionsDir := filepath.Join(root, "workspace", "sessions")
	if err := os.MkdirAll(sessionsDir, 0o755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}

	strayDir := filepath.Join(sessionsDir, "not-a-date")
	if err := os.MkdirAll(strayDir, 0o755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	strayFile := filepath.Join(sessionsDir, "README.md")
	if err := os.WriteFile(strayFile, []byte("keep me"), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	msgs := []agentctx.StrategicMessage{{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: strPtr("x")}}}
	if err := l.Log("s1", 1, msgs); err != nil {
		t.Fatalf("Log: %v", err)
	}

	for _, p := range []string{strayDir, strayFile} {
		if _, err := os.Stat(p); err != nil {
			t.Errorf("expected %s untouched, stat err = %v", p, err)
		}
	}
}

func TestMarkdownLogger_PruneReturnsNilWhenNothingToPrune(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	l := NewMarkdownLogger(root)

	// sessionsDir does not exist yet.
	if err := l.pruneOldSessions(time.Now().UTC()); err != nil {
		t.Fatalf("pruneOldSessions on missing dir: %v", err)
	}

	msgs := []agentctx.StrategicMessage{{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: strPtr("x")}}}
	if err := l.Log("s1", 1, msgs); err != nil {
		t.Fatalf("Log: %v", err)
	}
	// Successful write with nothing prunable still returns nil.
	if err := l.pruneOldSessions(time.Now().UTC()); err != nil {
		t.Fatalf("pruneOldSessions with only recent dir: %v", err)
	}
}

func TestSanitizeKey(t *testing.T) {
	t.Parallel()
	tests := []struct{ in, want string }{
		{"abc123", "abc123"},
		{"123:456", "123_456"},
		{"hello/world", "hello_world"},
		{"a-b_c", "a-b_c"},
	}
	for _, tc := range tests {
		if got := sanitizeKey(tc.in); got != tc.want {
			t.Errorf("sanitizeKey(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}
