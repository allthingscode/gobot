//nolint:testpackage // intentionally uses unexported helpers from main package
package app

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

// mockMemoryStore is a test double for MemoryStore.
type mockMemoryStore struct {
	results        []map[string]any
	err            error
	lastQuery      string
	lastSessionKey string
	lastLimit      int
}

func (m *mockMemoryStore) Search(query, sessionKey string, limit int) ([]map[string]any, error) {
	m.lastQuery = query
	m.lastSessionKey = sessionKey
	m.lastLimit = limit
	return m.results, m.err
}

func (m *mockMemoryStore) Index(namespace, content string) error { return nil }
func (m *mockMemoryStore) Close() error                         { return nil }
func (m *mockMemoryStore) Rebuild(sessionDir string) (int, error) { return 0, nil }

func TestMemoryTool_Name(t *testing.T) {
	t.Parallel()
	tool := &MemoryTool{store: &mockMemoryStore{}}
	if tool.Name() != memoryToolName {
		t.Errorf("Name() = %q, want %q", tool.Name(), memoryToolName)
	}
}

func TestMemoryTool_Declaration(t *testing.T) {
	t.Parallel()
	tool := &MemoryTool{store: &mockMemoryStore{}}
	decl := tool.Declaration()
	if decl.Name != memoryToolName {
		t.Errorf("Declaration.Name = %q, want %q", decl.Name, memoryToolName)
	}
	// Parameters is an any, usually a struct from DeriveSchema
	if decl.Parameters == nil {
		t.Error("Declaration missing parameters")
	}
}

func TestMemoryTool_Execute_ReturnsJSON(t *testing.T) {
	t.Parallel()
	mock := &mockMemoryStore{
		results: []map[string]any{
			{"content": "Project Alpha deadline is May 1", "session_key": "s1", "timestamp": "2026-01-01T00:00:00Z"},
			{"content": "Budget approved for Q2", "session_key": "s2", "timestamp": "2026-01-02T00:00:00Z"},
		},
	}
	tool := &MemoryTool{store: mock}
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

func TestMemoryTool_Execute_NoResults(t *testing.T) {
	t.Parallel()
	tool := &MemoryTool{store: &mockMemoryStore{results: nil}}
	got, err := tool.Execute(context.Background(), "sess", "", map[string]any{"query": "unknown topic"})
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
	if !strings.Contains(got, "No relevant memories") {
		t.Errorf("expected no-results message, got %q", got)
	}
}

func TestMemoryTool_Execute_EmptyQuery(t *testing.T) {
	t.Parallel()
	tool := &MemoryTool{store: &mockMemoryStore{}}
	_, err := tool.Execute(context.Background(), "sess", "", map[string]any{"query": ""})
	if err == nil {
		t.Error("expected error for empty query, got nil")
	}
}
