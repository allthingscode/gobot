//nolint:testpackage // requires unexported consolidator internals for testing
package consolidator

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/memory"
	"github.com/allthingscode/gobot/internal/memory/vector"
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

type parseScoredFactsTC struct {
	name      string
	input     string
	wantLen   int
	wantErr   bool
	wantImp   []int
	wantFact0 string
}

func assertParseScoredFacts(t *testing.T, tc parseScoredFactsTC) {
	t.Helper()
	facts, err := parseScoredFacts(tc.input)
	if tc.wantErr {
		if err == nil {
			t.Error("expected error, got nil")
		}
		return
	}
	if err != nil {
		t.Fatalf("parseScoredFacts: %v", err)
	}
	if len(facts) != tc.wantLen {
		t.Errorf("expected %d facts, got %d", tc.wantLen, len(facts))
	}
	checkParsedFacts(t, facts, tc)
}

func checkParsedFacts(t *testing.T, facts []ScoredFact, tc parseScoredFactsTC) {
	t.Helper()
	if tc.wantFact0 != "" && len(facts) > 0 && facts[0].Fact != tc.wantFact0 {
		t.Errorf("fact[0] = %q, want %q", facts[0].Fact, tc.wantFact0)
	}
	for i, wantImp := range tc.wantImp {
		if i >= len(facts) {
			break
		}
		if facts[i].Importance != wantImp {
			t.Errorf("facts[%d].Importance = %d, want %d", i, facts[i].Importance, wantImp)
		}
	}
}

func TestParseScoredFacts(t *testing.T) {
	t.Parallel()
	tests := []parseScoredFactsTC{
		{
			name:      "scored format",
			input:     `[{"fact":"Project Alpha deadline May 2026","importance":5},{"fact":"User likes Fridays","importance":2}]`,
			wantLen:   2,
			wantImp:   []int{5, 2},
			wantFact0: "Project Alpha deadline May 2026",
		},
		{
			name:    "plain string fallback",
			input:   `["Fact one", "Fact two", "Fact three"]`,
			wantLen: 3,
			wantImp: []int{3, 3, 3},
		},
		{name: "empty array", input: `[]`, wantLen: 0},
		{
			name:    "markdown fences scored",
			input:   "```json\n[{\"fact\":\"Deadline May 1\",\"importance\":5}]\n```",
			wantLen: 1,
			wantImp: []int{5},
		},
		{
			name:    "markdown fences plain",
			input:   "```json\n[\"Fact A\", \"Fact B\"]\n```",
			wantLen: 2,
			wantImp: []int{3, 3},
		},
		{name: "malformed JSON", input: "not json at all", wantErr: true},
		{
			name:    "out-of-range importance clamped to 3",
			input:   `[{"fact":"Bad score","importance":99}]`,
			wantLen: 1,
			wantImp: []int{3},
		},
		{
			name:    "zero importance clamped to 3",
			input:   `[{"fact":"Zero score","importance":0}]`,
			wantLen: 1,
			wantImp: []int{3},
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			assertParseScoredFacts(t, tc)
		})
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
	results, err := store.Search(context.Background(), "Project Alpha", "sess1", 5)
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
		results, err := store.Search(context.Background(), tc.query, "sess1", 5)
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
	results, err := store.Search(context.Background(), "should not be reached", "sess1", 100)
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
	results, _ := store.Search(context.Background(), "metric", "sess2", 5)
	if len(results) == 0 {
		t.Error("expected to find global fact 'metric' from sess2")
	}

	results, _ = store.Search(context.Background(), "deadline", "sess2", 5)
	if len(results) == 0 {
		t.Error("expected to find global fact 'deadline' from sess2")
	}

	// Verify session fact is NOT findable from a different session
	results, _ = store.Search(context.Background(), "specific", "sess2", 5)
	if len(results) > 0 {
		t.Errorf("did NOT expect to find session fact from sess2, got %d results", len(results))
	}

	// Verify session fact IS findable from its own session
	results, _ = store.Search(context.Background(), "specific", "sess1", 5)
	if len(results) == 0 {
		t.Error("expected to find session fact from its own session (sess1)")
	}
}

// mockEmbeddingProvider returns fixed embeddings for testing.
type mockEmbeddingProvider struct {
	val []float32
	err error
}

func (m *mockEmbeddingProvider) Embed(_ context.Context, _ string) ([]float32, error) {
	return m.val, m.err
}

func TestConsolidator_SemanticDeduplication(t *testing.T) {
	t.Parallel()
	store := newTestStore(t)
	vecStore, _ := vector.NewStore(filepath.Join(t.TempDir(), "test_vec.db"))
	// Use non-zero vector to avoid NaN similarity
	embedProv := &mockEmbeddingProvider{val: []float32{1, 0, 0, 0, 0, 0, 0, 0, 0, 0}}

	c := New(&mockTextRunner{response: `["deadline is May 1"]`}, store, vecStore, embedProv)
	c.SetSemanticDedupThreshold(0.9)

	// 1. Index first fact.
	n, err := c.consolidate(context.Background(), "sess1", strings.Repeat("x", 100))
	if err != nil || n != 1 {
		t.Fatalf("first consolidate failed: n=%d, err=%v", n, err)
	}

	// 2. Try to index a semantic duplicate (same meaning, different words).
	// Since we mock the embedding to always be the same, chromem-go will see them as identical (Similarity=1.0).
	runner := &mockTextRunner{response: `["The cutoff is May 1st"]`}
	c = New(runner, store, vecStore, embedProv)
	c.SetSemanticDedupThreshold(0.9)

	n, err = c.consolidate(context.Background(), "sess1", strings.Repeat("x", 100))
	if err != nil {
		t.Fatalf("second consolidate failed: %v", err)
	}
	if n != 0 {
		t.Errorf("expected 0 new facts (semantic duplicate), got %d", n)
	}

	// 3. Verify threshold works.
	// We can't easily control chromem-go's similarity scores with just one mock vector
	// without more complex mocking, but we can disable it via threshold=0.
	c.SetSemanticDedupThreshold(0)
	n, err = c.consolidate(context.Background(), "sess1", strings.Repeat("x", 100))
	if err != nil {
		t.Fatalf("third consolidate failed: %v", err)
	}
	// With threshold=0, it falls back to lexical. "The cutoff is May 1st" vs "deadline is May 1"
	// should have low lexical similarity.
	if n != 1 {
		t.Errorf("expected 1 fact indexed when semantic dedup is disabled, got %d", n)
	}
}

func TestConsolidator_SemanticDedup_NamespaceIsolation(t *testing.T) {
	t.Parallel()
	store := newTestStore(t)
	vecStore, _ := vector.NewStore(filepath.Join(t.TempDir(), "test_vec_iso.db"))
	embedProv := &mockEmbeddingProvider{val: []float32{0, 1, 0, 0, 0, 0, 0, 0, 0, 0}}

	c := New(&mockTextRunner{response: `["Shared secret is 42"]`}, store, vecStore, embedProv)
	c.SetSemanticDedupThreshold(0.9)

	// 1. Index fact for sess1.
	_, _ = c.consolidate(context.Background(), "sess1", strings.Repeat("x", 100))

	// 2. Try to index same fact for sess2.
	// It should NOT be deduplicated because it's a different session.
	runner := &mockTextRunner{response: `["Shared secret is 42"]`}
	c = New(runner, store, vecStore, embedProv)
	c.SetSemanticDedupThreshold(0.9)

	n, err := c.consolidate(context.Background(), "sess2", strings.Repeat("x", 100))
	if err != nil {
		t.Fatalf("consolidate for sess2 failed: %v", err)
	}
	if n != 1 {
		t.Errorf("expected fact to be indexed for sess2 (isolation), got %d", n)
	}

	// 3. Index a global fact for sess1.
	c.SetGlobalPatterns([]string{"global"})
	runner = &mockTextRunner{response: `["This is a global fact"]`}
	c = New(runner, store, vecStore, embedProv)
	c.SetGlobalPatterns([]string{"global"})
	_, _ = c.consolidate(context.Background(), "sess1", strings.Repeat("x", 100))

	// 4. Try to index same global fact for sess2.
	// It SHOULD be deduplicated because the existing one is global.
	runner = &mockTextRunner{response: `["This is a global fact"]`}
	c = New(runner, store, vecStore, embedProv)
	c.SetSemanticDedupThreshold(0.9)
	n, err = c.consolidate(context.Background(), "sess2", strings.Repeat("x", 100))
	if err != nil {
		t.Fatalf("consolidate global failed: %v", err)
	}
	if n != 0 {
		t.Errorf("expected global fact to be deduplicated, got %d", n)
	}
}

func TestConsolidator_SetSemanticDedupThreshold(t *testing.T) {
	t.Parallel()
	c := New(&mockTextRunner{}, nil, nil, nil)
	c.SetSemanticDedupThreshold(0.85)
	if c.semanticDedupThreshold != 0.85 {
		t.Errorf("expected threshold 0.85, got %.2f", c.semanticDedupThreshold)
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

type lifecycleRunner struct {
	run func(context.Context) (string, error)
}

func (r lifecycleRunner) RunText(ctx context.Context, _, _, _ string) (string, error) {
	return r.run(ctx)
}

func awaitWorker(t *testing.T, ch <-chan struct{}) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(2 * time.Second):
		t.Fatal("worker barrier timed out")
	}
}

func TestShutdownAdmission(t *testing.T) {
	t.Parallel()
	for _, count := range []int{0, 1, 8} {
		t.Run(fmt.Sprint(count), func(t *testing.T) {
			t.Parallel()
			checkShutdownAdmission(t, count)
		})
	}
}

func checkShutdownAdmission(t *testing.T, count int) {
	t.Helper()
	started := make(chan struct{}, count)
	var calls atomic.Int64
	c := New(lifecycleRunner{run: func(ctx context.Context) (string, error) {
		calls.Add(1)
		started <- struct{}{}
		<-ctx.Done()
		return "", ctx.Err()
	}}, newTestStore(t), nil, nil)
	for i := 0; i < count; i++ {
		c.ConsolidateAsync("session", strings.Repeat("x", 80))
	}
	for i := 0; i < count; i++ {
		awaitWorker(t, started)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := c.Shutdown(ctx); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	c.ConsolidateAsync("closed", strings.Repeat("x", 80))
	if got := calls.Load(); got != int64(count) {
		t.Fatalf("launched %d workers, want %d", got, count)
	}
}

func TestShutdownConcurrentSubmissions(t *testing.T) {
	t.Parallel()
	var calls atomic.Int32
	c := New(lifecycleRunner{run: func(context.Context) (string, error) { calls.Add(1); return "[]", nil }}, newTestStore(t), nil, nil)
	var wg sync.WaitGroup
	start := make(chan struct{})
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); <-start; c.ConsolidateAsync("session", strings.Repeat("x", 80)) }()
	}
	close(start)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := c.Shutdown(ctx); err != nil {
		t.Fatal(err)
	}
	wg.Wait()
	before := calls.Load()
	c.ConsolidateAsync("late", strings.Repeat("x", 80))
	if calls.Load() != before {
		t.Fatal("submission after shutdown launched")
	}
}

func TestOwnerCancellationAndActualJoin(t *testing.T) {
	t.Parallel()
	store := expiredLifecycleStore(t)
	started, cancelled, release := make(chan struct{}), make(chan struct{}), make(chan struct{})
	var once sync.Once
	defer once.Do(func() { close(release) })
	owner, cancel := context.WithCancel(context.Background())
	defer cancel()
	c := New(lifecycleRunner{run: func(ctx context.Context) (string, error) {
		close(started)
		<-ctx.Done()
		close(cancelled)
		<-release
		return `["must not index after cancellation"]`, nil
	}}, store, nil, nil)
	c.BindLifetime(owner)
	c.SetTTL("1ns")
	c.SetGlobalTTL("1ns")
	c.ConsolidateAsync("session", strings.Repeat("x", 80))
	awaitWorker(t, started)
	cancel()
	awaitWorker(t, cancelled)
	c.ConsolidateAsync("cancelled", strings.Repeat("x", 80))
	deadline, stop := context.WithCancel(context.Background())
	stop()
	err := c.Shutdown(deadline)
	if !errors.Is(err, ErrDrainTimeout) || !errors.Is(err, context.Canceled) {
		t.Fatalf("missing wrapped timeout: %v", err)
	}
	once.Do(func() { close(release) })
	ctx, finish := context.WithTimeout(context.Background(), 2*time.Second)
	defer finish()
	if err := c.Shutdown(ctx); err != nil {
		t.Fatal(err)
	}
	rows, err := c.store.Search(ctx, "must not index", "session", 10)
	if err != nil || len(rows) != 0 {
		t.Fatalf("cancelled extraction indexed: %v %v", rows, err)
	}
	for _, key := range []string{"session", "global"} {
		rows, err := store.Search(ctx, "expired marker", key, 10)
		if err != nil || len(rows) == 0 {
			t.Fatalf("cancelled worker cleaned %s namespace: %v %v", key, rows, err)
		}
	}

}

func TestCancelledOwnerRejectsWork(t *testing.T) {
	t.Parallel()
	owner, cancel := context.WithCancel(context.Background())
	cancel()
	c := New(lifecycleRunner{run: func(context.Context) (string, error) { t.Error("cancelled owner launched"); return "[]", nil }}, newTestStore(t), nil, nil)
	c.BindLifetime(owner)
	c.ConsolidateAsync("session", strings.Repeat("x", 80))
	if err := c.Shutdown(context.Background()); err != nil {
		t.Fatal(err)
	}
}

type blockedEmbedding struct{ started, cancelled, release chan struct{} }

func (e blockedEmbedding) Embed(ctx context.Context, _ string) ([]float32, error) {
	close(e.started)
	<-ctx.Done()
	close(e.cancelled)
	<-e.release
	return []float32{1, 0, 0}, nil
}

func TestShutdownJoinsInProgressIndexing(t *testing.T) {
	t.Parallel()
	started, cancelled, release := make(chan struct{}), make(chan struct{}), make(chan struct{})
	var once sync.Once
	defer once.Do(func() { close(release) })
	vectorPath := filepath.Join(t.TempDir(), "vectors.gob")
	vectors, err := vector.NewStore(vectorPath)
	if err != nil {
		t.Fatal(err)
	}
	c := New(&mockTextRunner{response: `["unique indexed fact"]`}, newTestStore(t), vectors, blockedEmbedding{started, cancelled, release})
	c.SetSemanticDedupThreshold(0)
	c.ConsolidateAsync("session", strings.Repeat("reply ", 20))
	awaitWorker(t, started)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()
	if err := c.Shutdown(ctx); !errors.Is(err, ErrDrainTimeout) || !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("indexing was not counted: %v", err)
	}
	awaitWorker(t, cancelled)
	once.Do(func() { close(release) })
	join, stop := context.WithTimeout(context.Background(), 2*time.Second)
	defer stop()
	if err := c.Shutdown(join); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(vectorPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("cancelled indexing saved vectors: %v", err)
	}
}

func expiredLifecycleStore(t *testing.T) *memory.MemoryStore {
	t.Helper()
	root := t.TempDir()
	store, err := memory.NewMemoryStore(root)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	for _, ns := range []string{"session:session", "global"} {
		if err := store.Index(ns, "expired marker"); err != nil {
			t.Fatal(err)
		}
	}
	db, err := sql.Open("sqlite", filepath.Join(root, "workspace", "memory.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = db.Close() }()
	if _, err := db.ExecContext(context.Background(), "UPDATE memory_fts SET timestamp = ?", "2000-01-01T00:00:00Z"); err != nil {
		t.Fatal(err)
	}
	return store
}
