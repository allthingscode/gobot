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
