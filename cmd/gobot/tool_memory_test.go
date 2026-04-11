package main

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/config"
)

// mockMemorySearcher is a test double for memorySearcher.
type mockMemorySearcher struct {
	results       []map[string]any
	err           error
	lastQuery     string
	lastSessionKey string
	lastLimit     int
}

func (m *mockMemorySearcher) Search(query, sessionKey string, limit int) ([]map[string]any, error) {
	m.lastQuery = query
	m.lastSessionKey = sessionKey
	m.lastLimit = limit
	return m.results, m.err
}

func TestSearchMemoryTool_Name(t *testing.T) {
	t.Parallel()
	tool := &SearchMemoryTool{store: &mockMemorySearcher{}, cfg: &config.Config{}}
	if tool.Name() != searchMemoryToolName {
		t.Errorf("Name() = %q, want %q", tool.Name(), searchMemoryToolName)
	}
}

func TestSearchMemoryTool_Declaration(t *testing.T) {
	t.Parallel()
	tool := &SearchMemoryTool{store: &mockMemorySearcher{}, cfg: &config.Config{}}
	decl := tool.Declaration()
	if decl.Name != searchMemoryToolName {
		t.Errorf("Declaration.Name = %q, want %q", decl.Name, searchMemoryToolName)
	}
	props, _ := decl.Parameters["properties"].(map[string]any)
	if _, ok := props["query"]; !ok {
		t.Error("Declaration missing 'query' parameter")
	}
	if _, ok := props["limit"]; !ok {
		t.Error("Declaration missing 'limit' parameter")
	}
}

func TestSearchMemoryTool_Execute_ReturnsJSON(t *testing.T) {
	t.Parallel()
	mock := &mockMemorySearcher{
		results: []map[string]any{
			{"content": "Project Alpha deadline is May 1", "session_key": "s1", "timestamp": "2026-01-01T00:00:00Z"},
			{"content": "Budget approved for Q2", "session_key": "s2", "timestamp": "2026-01-02T00:00:00Z"},
		},
	}
	tool := &SearchMemoryTool{store: mock, cfg: &config.Config{}}
	got, err := tool.Execute(context.Background(), "sess", "", map[string]any{"query": "Project Alpha"})
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}

	var results []map[string]any
	if err := json.Unmarshal([]byte(got), &results); err != nil {
		t.Fatalf("result is not valid JSON: %v\ngot: %s", err, got)
	}
	if len(results) != 2 {
		t.Errorf("expected 2 results, got %d", len(results))
	}
	if mock.lastQuery != "Project Alpha" {
		t.Errorf("query passed to store = %q, want %q", mock.lastQuery, "Project Alpha")
	}
}

func TestSearchMemoryTool_Execute_NoResults(t *testing.T) {
	t.Parallel()
	tool := &SearchMemoryTool{store: &mockMemorySearcher{results: nil}, cfg: &config.Config{}}
	got, err := tool.Execute(context.Background(), "sess", "", map[string]any{"query": "unknown topic"})
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
	if !strings.Contains(got, "No matching memories") {
		t.Errorf("expected no-results message, got %q", got)
	}
}

func TestSearchMemoryTool_Execute_EmptyQuery(t *testing.T) {
	t.Parallel()
	tool := &SearchMemoryTool{store: &mockMemorySearcher{}, cfg: &config.Config{}}
	_, err := tool.Execute(context.Background(), "sess", "", map[string]any{"query": ""})
	if err == nil {
		t.Error("expected error for empty query, got nil")
	}
}

func TestSearchMemoryTool_Execute_DefaultLimit(t *testing.T) {
	t.Parallel()
	mock := &mockMemorySearcher{results: nil}
	tool := &SearchMemoryTool{store: mock, cfg: &config.Config{}}
	_, _ = tool.Execute(context.Background(), "sess", "", map[string]any{"query": "test"})
	if mock.lastLimit != 5 {
		t.Errorf("expected default limit 5, got %d", mock.lastLimit)
	}
}

func TestSearchMemoryTool_Execute_CustomLimit(t *testing.T) {
	t.Parallel()
	mock := &mockMemorySearcher{results: nil}
	tool := &SearchMemoryTool{store: mock, cfg: &config.Config{}}
	_, _ = tool.Execute(context.Background(), "sess", "", map[string]any{"query": "test", "limit": float64(3)})
	if mock.lastLimit != 3 {
		t.Errorf("expected limit 3, got %d", mock.lastLimit)
	}
}
