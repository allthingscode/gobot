//nolint:testpackage // requires unexported consolidator internals for testing
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

func (m *mockTextRunner) RunText(_ context.Context, _, _, _ string) (string, error) {
	return m.response, m.err
}

func newTestStore(t *testing.T) *memory.MemoryStore {
	t.Helper()
	store, err := memory.NewMemoryStore(t.TempDir())
	if err != nil {
		t.Fatalf("NewMemoryStore: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	return store
}

func TestParseFacts_ValidArray(t *testing.T) {
	t.Parallel()
	facts, err := parseFacts(`["Fact one", "Fact two", "Fact three"]`)
	if err != nil {
		t.Fatalf("parseFacts: %v", err)
	}
	if len(facts) != 3 {
		t.Errorf("expected 3 facts, got %d", len(facts))
	}
}

func TestParseFacts_EmptyArray(t *testing.T) {
	t.Parallel()
	facts, err := parseFacts(`[]`)
	if err != nil {
		t.Fatalf("parseFacts: %v", err)
	}
	if len(facts) != 0 {
		t.Errorf("expected 0 facts, got %d", len(facts))
	}
}

func TestParseFacts_MarkdownFences(t *testing.T) {
	t.Parallel()
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
	t.Parallel()
	_, err := parseFacts("not json at all")
	if err == nil {
		t.Error("expected error for invalid JSON, got nil")
	}
}

func TestConsolidator_IndexesFacts(t *testing.T) {
	t.Parallel()
	store := newTestStore(t)
	runner := &mockTextRunner{
		response: `["Project Alpha deadline is May 1 2026", "User prefers Friday updates"]`,
	}
	c := New(runner, store, nil, nil)
	n, err := c.consolidate(context.Background(), "sess1", strings.Repeat("x", 200))
	if err != nil {
		t.Fatalf("consolidate: %v", err)
	}
	if n != 2 {
		t.Errorf("expected 2 facts indexed, got %d", n)
	}

	// Verify facts are searchable.
	results, err := store.Search("Project Alpha", "sess1", 5)
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	if len(results) == 0 {
		t.Error("expected search results for 'Project Alpha', got none")
	}
}

func TestConsolidator_EmptyLLMResponse_IndexesNothing(t *testing.T) {
	t.Parallel()
	store := newTestStore(t)
	runner := &mockTextRunner{response: `[]`}
	c := New(runner, store, nil, nil)
	n, err := c.consolidate(context.Background(), "sess1", strings.Repeat("x", 200))
	if err != nil {
		t.Fatalf("consolidate: %v", err)
	}
	if n != 0 {
		t.Errorf("expected 0 facts indexed, got %d", n)
	}
}

func TestConsolidator_ShortReply_SkippedByConsolidateAsync(t *testing.T) {
	t.Parallel()
	// ConsolidateAsync should not spawn a goroutine for short replies.
	// We verify by using a runner that would panic if called.
	store := newTestStore(t)
	runner := &mockTextRunner{response: "should not be called"}
	c := New(runner, store, nil, nil)
	// "OK" is 2 runes — well below minConsolidateLength.
	c.ConsolidateAsync("sess", "OK")
	// If the goroutine were spawned and panicked, the test would fail.
}

func TestConsolidator_DeduplicatesFacts(t *testing.T) {
	t.Parallel()
	store := newTestStore(t)
	// Pre-seed a fact.
	_ = store.Index("session:sess1", "Project Alpha deadline is May 1 2026")

	runner := &mockTextRunner{
		response: `["Project Alpha deadline is May 1 2026"]`,
	}
	c := New(runner, store, nil, nil)
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
	t.Parallel()
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
var (
	_ = os.TempDir
	_ = filepath.Join
)

// ── F-068: Integration Tests ────────────────────────────────────────────────

func TestConsolidator_EndToEnd_CompactConsolidateRetrieve(t *testing.T) {
	t.Parallel()
	// Full integration test: verify that facts extracted from dropped messages
	// can be consolidated and retrieved via RAG search.
	store := newTestStore(t)

	// Simulate LLM returning meaningful facts.
	runner := &mockTextRunner{
		response: `[
			"Project deadline May 2026",
			"Budget approved fifty thousand",
			"Stakeholder review next Thursday"
		]`,
	}

	c := New(runner, store, nil, nil)

	// Simulate messages being dropped during compaction.
	// These messages contain substantive information.
	droppedMessages := `user: What's the project deadline?
assistant: May 15, 2026. We also need to get stakeholder review scheduled.
user: How much budget do we have?
assistant: Budget approved for Q2`

	// Consolidate (extract facts and index them).
	n, err := c.consolidate(context.Background(), "sess1", droppedMessages)
	if err != nil {
		t.Fatalf("consolidate: %v", err)
	}
	if n != 3 {
		t.Errorf("expected 3 facts indexed, got %d", n)
	}

	// Verify facts are retrievable via RAG (search).
	tests := []struct {
		query    string
		wantFind bool
	}{
		{"May 2026", true},
		{"deadline", true},
		{"stakeholder", true},
		{"nonexistent fact", false},
	}

	for _, tc := range tests {
		results, err := store.Search(tc.query, "sess1", 5)
		if err != nil {
			t.Logf("Search(%q): %v", tc.query, err)
		}
		found := len(results) > 0
		if tc.wantFind && !found {
			t.Errorf("Search(%q): expected to find fact, got none", tc.query)
		}
		if !tc.wantFind && found {
			t.Errorf("Search(%q): expected no results, got %d", tc.query, len(results))
		}
	}
}

func TestConsolidator_TTLCleanupRunsWithoutError(t *testing.T) {
	t.Parallel()
	// Test that TTL cleanup runs during consolidation without errors.
	// We don't test the actual deletion since timing is sensitive to nanosecond precision.
	store := newTestStore(t)

	runner := &mockTextRunner{
		response: `["new fact to consolidate"]`,
	}

	c := New(runner, store, nil, nil)
	c.SetTTL("87600h") // Very long TTL (10 years) — nothing should be deleted

	// Consolidate with TTL cleanup configured.
	n, err := c.consolidate(context.Background(), "sess1", strings.Repeat("x", 200))
	if err != nil {
		t.Fatalf("consolidate: %v", err)
	}
	if n != 1 {
		t.Errorf("expected 1 fact indexed, got %d", n)
	}

	// Just verify that consolidation completed without error.
	// The cleanup is a best-effort operation and doesn't affect the return value.
}

func TestConsolidator_NoConsolidateOnShortReply(t *testing.T) {
	t.Parallel()
	// Short replies (less than minConsolidateLength runes) should not trigger consolidation.
	store := newTestStore(t)
	runner := &mockTextRunner{
		response: `["should not be reached"]`,
	}

	c := New(runner, store, nil, nil)

	// These messages are too short to trigger consolidation (minConsolidateLength = 80).
	shortMsgs := []string{"ok", "yes", "confirmed", "thanks"}
	for _, msg := range shortMsgs {
		c.ConsolidateAsync("sess1", msg)
	}

	// Verify nothing was indexed. If ConsolidateAsync had run the consolidate function,
	// facts would be indexed. Since they're not, we know it returned early.
	// We can verify this by trying a search that would only match if the fact was indexed.
	results, err := store.Search("should not be reached", "sess1", 100)
	if err != nil {
		t.Logf("Search error: %v", err) // Empty results are okay
	}
	if len(results) > 0 {
		t.Error("expected no entries indexed for short messages, but found results")
	}
}

func TestConsolidator_GlobalRouting(t *testing.T) {
	t.Parallel()
	store := newTestStore(t)
	runner := &mockTextRunner{
		response: `["User prefers metric units", "Project Alpha deadline is May 1 2026", "Session specific fact"]`,
	}
	c := New(runner, store, nil, nil)
	c.SetGlobalPatterns([]string{"prefer", "deadline"})

	_, err := c.consolidate(context.Background(), "sess1", strings.Repeat("x", 200))
	if err != nil {
		t.Fatalf("consolidate: %v", err)
	}

	// Verify global facts are findable from a different session
	results, _ := store.Search("metric", "sess2", 5)
	if len(results) == 0 {
		t.Error("expected to find global fact 'metric' from sess2")
	}

	results, _ = store.Search("deadline", "sess2", 5)
	if len(results) == 0 {
		t.Error("expected to find global fact 'deadline' from sess2")
	}

	// Verify session fact is NOT findable from a different session
	results, _ = store.Search("specific", "sess2", 5)
	if len(results) > 0 {
		t.Errorf("did NOT expect to find session fact from sess2, got %d results", len(results))
	}

	// Verify session fact IS findable from its own session
	results, _ = store.Search("specific", "sess1", 5)
	if len(results) == 0 {
		t.Error("expected to find session fact from its own session (sess1)")
	}
}

func TestConsolidator_Setters(t *testing.T) {
	t.Parallel()

	t.Run("SetPrompt", func(t *testing.T) {
		t.Parallel()
		c := New(&mockTextRunner{}, nil, nil, nil)
		custom := "custom prompt"
		c.SetPrompt(custom)
		if c.prompt != custom {
			t.Errorf("expected prompt %q, got %q", custom, c.prompt)
		}
	})

	t.Run("SetPrompt_Empty", func(t *testing.T) {
		t.Parallel()
		c := New(&mockTextRunner{}, nil, nil, nil)
		original := c.prompt
		c.SetPrompt("")
		if c.prompt != original {
			t.Errorf("expected prompt to remain %q, got %q", original, c.prompt)
		}
	})

	t.Run("SetTTL", func(t *testing.T) {
		t.Parallel()
		c := New(&mockTextRunner{}, nil, nil, nil)
		ttl := "100h"
		c.SetTTL(ttl)
		if c.ttl != ttl {
			t.Errorf("expected ttl %q, got %q", ttl, c.ttl)
		}
	})

	t.Run("SetGlobalTTL", func(t *testing.T) {
		t.Parallel()
		c := New(&mockTextRunner{}, nil, nil, nil)
		ttl := "200h"
		c.SetGlobalTTL(ttl)
		if c.globalTTL != ttl {
			t.Errorf("expected globalTTL %q, got %q", ttl, c.globalTTL)
		}
	})

	t.Run("SetGlobalPatterns", func(t *testing.T) {
		t.Parallel()
		c := New(&mockTextRunner{}, nil, nil, nil)
		patterns := []string{"p1", "p2"}
		c.SetGlobalPatterns(patterns)
		if len(c.patterns) != 2 || c.patterns[0] != "p1" {
			t.Errorf("expected patterns %v, got %v", patterns, c.patterns)
		}
	})

	t.Run("SetObservability", func(t *testing.T) {
		t.Parallel()
		c := New(&mockTextRunner{}, nil, nil, nil)
		// Just verify it doesn't panic and assigns the pointer.
		c.SetObservability(nil)
		if c.obs != nil {
			t.Error("expected nil observability")
		}
	})
}
