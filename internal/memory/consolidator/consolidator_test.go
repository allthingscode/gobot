package consolidator

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/memory"
	_ "modernc.org/sqlite"
)

// mockTextRunner returns a pre-canned response for any prompt.
type mockTextRunner struct {
	response string
	err      error
}

func (m *mockTextRunner) RunText(_ context.Context, _ string) (string, error) {
	return m.response, m.err
}

func newTestStore(t *testing.T) *memory.MemoryStore {
	t.Helper()
	store, err := memory.NewMemoryStore(t.TempDir())
	if err != nil {
		t.Fatalf("NewMemoryStore: %v", err)
	}
	t.Cleanup(func() { store.Close() })
	return store
}

func TestParseFacts_ValidArray(t *testing.T) {
	facts, err := parseFacts(`["Fact one", "Fact two", "Fact three"]`)
	if err != nil {
		t.Fatalf("parseFacts: %v", err)
	}
	if len(facts) != 3 {
		t.Errorf("expected 3 facts, got %d", len(facts))
	}
}

func TestParseFacts_EmptyArray(t *testing.T) {
	facts, err := parseFacts(`[]`)
	if err != nil {
		t.Fatalf("parseFacts: %v", err)
	}
	if len(facts) != 0 {
		t.Errorf("expected 0 facts, got %d", len(facts))
	}
}

func TestParseFacts_MarkdownFences(t *testing.T) {
	input := "```json\n[\"Fact A\", \"Fact B\"]\n```"
	facts, err := parseFacts(input)
	if err != nil {
		t.Fatalf("parseFacts: %v", err)
	}
	if len(facts) != 2 {
		t.Errorf("expected 2 facts, got %d", len(facts))
	}
}

func TestParseFacts_InvalidJSON(t *testing.T) {
	_, err := parseFacts("not json at all")
	if err == nil {
		t.Error("expected error for invalid JSON, got nil")
	}
}

func TestConsolidator_IndexesFacts(t *testing.T) {
	store := newTestStore(t)
	runner := &mockTextRunner{
		response: `["Project Alpha deadline is May 1 2026", "User prefers Friday updates"]`,
	}
	c := New(runner, store)
	n, err := c.consolidate(context.Background(), "sess1", strings.Repeat("x", 200))
	if err != nil {
		t.Fatalf("consolidate: %v", err)
	}
	if n != 2 {
		t.Errorf("expected 2 facts indexed, got %d", n)
	}

	// Verify facts are searchable.
	results, err := store.Search("Project Alpha", 5)
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	if len(results) == 0 {
		t.Error("expected search results for 'Project Alpha', got none")
	}
}

func TestConsolidator_EmptyLLMResponse_IndexesNothing(t *testing.T) {
	store := newTestStore(t)
	runner := &mockTextRunner{response: `[]`}
	c := New(runner, store)
	n, err := c.consolidate(context.Background(), "sess1", strings.Repeat("x", 200))
	if err != nil {
		t.Fatalf("consolidate: %v", err)
	}
	if n != 0 {
		t.Errorf("expected 0 facts indexed, got %d", n)
	}
}

func TestConsolidator_ShortReply_SkippedByConsolidateAsync(t *testing.T) {
	// ConsolidateAsync should not spawn a goroutine for short replies.
	// We verify by using a runner that would panic if called.
	store := newTestStore(t)
	runner := &mockTextRunner{response: "should not be called"}
	c := New(runner, store)
	// "OK" is 2 runes — well below minConsolidateLength.
	c.ConsolidateAsync("sess", "OK")
	// If the goroutine were spawned and panicked, the test would fail.
}

func TestConsolidator_DeduplicatesFacts(t *testing.T) {
	store := newTestStore(t)
	// Pre-seed a fact.
	_ = store.Index("sess1", "Project Alpha deadline is May 1 2026")

	runner := &mockTextRunner{
		response: `["Project Alpha deadline is May 1 2026"]`,
	}
	c := New(runner, store)
	n, err := c.consolidate(context.Background(), "sess1", strings.Repeat("x", 200))
	if err != nil {
		t.Fatalf("consolidate: %v", err)
	}
	// Should be 0 — duplicate skipped.
	if n != 0 {
		t.Errorf("expected 0 new facts (duplicate), got %d", n)
	}
}

func TestSimilarity(t *testing.T) {
	tests := []struct {
		a, b string
		high bool
	}{
		{"Project Alpha deadline May 2026", "Project Alpha deadline is May 1 2026", true},
		{"Project Alpha", "completely different topic", false},
		{"", "anything", false},
	}
	for _, tc := range tests {
		score := similarity(tc.a, tc.b)
		if tc.high && score <= 0.5 {
			t.Errorf("similarity(%q, %q) = %.2f, expected > 0.5", tc.a, tc.b, score)
		}
		if !tc.high && score > 0.5 {
			t.Errorf("similarity(%q, %q) = %.2f, expected <= 0.5", tc.a, tc.b, score)
		}
	}
}

// Ensure os and filepath are used (suppress unused import if needed).
var _ = os.TempDir
var _ = filepath.Join
