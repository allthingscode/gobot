package vector

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/philippgille/chromem-go"
)

type mockSearcher struct {
	results []map[string]any
}

func (m *mockSearcher) Search(query, sessionKey string, limit int) ([]map[string]any, error) {
	return m.results, nil
}

type mockEmbedder struct{}

func (m *mockEmbedder) Embed(ctx context.Context, text string) ([]float32, error) {
	// Return a dummy embedding
	return make([]float32, 768), nil
}

func TestMergeResults(t *testing.T) {
	t.Parallel()
	fts := []FTSResult{
		{ID: "fts1", Content: "keyword match", Timestamp: "2026-04-10T10:00:00Z"},
		{ID: "fts2", Content: "another keyword", Timestamp: "2026-04-10T10:01:00Z"},
	}
	vec := []chromem.Result{
		{ID: "vec1", Content: "semantic match", Metadata: map[string]string{"timestamp": "2026-04-10T10:02:00Z"}},
		{ID: "fts1", Content: "keyword match", Metadata: map[string]string{"timestamp": "2026-04-10T10:00:00Z"}},
	}

	merged := MergeResults(fts, vec, 60)

	if len(merged) != 3 {
		t.Fatalf("expected 3 merged results, got %d", len(merged))
	}

	// fts1 should be first because it's in both
	if merged[0].ID != "fts1" {
		t.Errorf("expected first result to be fts1, got %s", merged[0].ID)
	}

	// Verify scores are descending
	for i := 1; i < len(merged); i++ {
		if merged[i].Score > merged[i-1].Score {
			t.Errorf("scores not descending: [%d]=%f > [%d]=%f", i, merged[i].Score, i-1, merged[i-1].Score)
		}
	}
}

func TestHybridSearch(t *testing.T) {
	t.Parallel()
	tmpDir, err := os.MkdirTemp("", "hybrid-test-*")
	if err != nil {
		t.Fatalf("MkdirTemp: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	dbPath := filepath.Join(tmpDir, "vectors.db")
	store, err := NewStore(dbPath)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}

	embedProv := &mockEmbedder{}
	embedFunc := func(ctx context.Context, text string) ([]float32, error) {
		return embedProv.Embed(ctx, text)
	}

	ctx := context.Background()

	// Seed vector store
	docs := []chromem.Document{
		{ID: "v1", Content: "semantic fact about projects", Metadata: map[string]string{
			"timestamp": "2026-04-10T10:00:00Z",
			"namespace": "session:f1",
		}},
	}
	if err := store.AddDocuments(ctx, "memory_facts", docs, embedFunc); err != nil {
		t.Fatalf("AddDocuments: %v", err)
	}

	fts := &mockSearcher{
		results: []map[string]any{
			{"namespace": "session:f1", "content": "keyword fact about projects", "timestamp": "2026-04-10T10:05:00Z"},
		},
	}

	results, err := HybridSearch(ctx, fts, store, embedProv, "projects", "f1", 5)
	if err != nil {
		t.Fatalf("HybridSearch: %v", err)
	}

	if len(results) != 2 {
		t.Fatalf("expected 2 results, got %d", len(results))
	}

	// Both should contain "projects"
	for _, r := range results {
		if !strings.Contains(strings.ToLower(r.Content), "projects") {
			t.Errorf("result %s content %q does not contain 'projects'", r.ID, r.Content)
		}
	}
}

func TestHybridSearch_Isolation(t *testing.T) {
	t.Parallel()
	tmpDir, err := os.MkdirTemp("", "hybrid-isolation-*")
	if err != nil {
		t.Fatalf("MkdirTemp: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	dbPath := filepath.Join(tmpDir, "vectors.db")
	store, err := NewStore(dbPath)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}

	embedProv := &mockEmbedder{}
	embedFunc := func(ctx context.Context, text string) ([]float32, error) {
		return embedProv.Embed(ctx, text)
	}

	ctx := context.Background()

	// Seed vector store with multiple namespaces
	docs := []chromem.Document{
		{ID: "v1", Content: "private fact from session A", Metadata: map[string]string{"namespace": "session:A"}},
		{ID: "v2", Content: "private fact from session B", Metadata: map[string]string{"namespace": "session:B"}},
		{ID: "v3", Content: "shared global fact", Metadata: map[string]string{"namespace": "global"}},
	}
	if err := store.AddDocuments(ctx, "memory_facts", docs, embedFunc); err != nil {
		t.Fatalf("AddDocuments: %v", err)
	}

	fts := &mockSearcher{} // returns empty

	// Search from session A
	results, err := HybridSearch(ctx, fts, store, embedProv, "fact", "A", 5)
	if err != nil {
		t.Fatalf("HybridSearch: %v", err)
	}

	// Should find v1 (session A) and v3 (global), but NOT v2 (session B)
	foundA := false
	foundGlobal := false
	for _, r := range results {
		if r.Content == "private fact from session A" {
			foundA = true
		}
		if r.Content == "private fact from session B" {
			t.Errorf("found private fact from session B while searching from session A")
		}
		if r.Content == "shared global fact" {
			foundGlobal = true
		}
	}

	if !foundA {
		t.Error("did not find private fact from session A")
	}
	if !foundGlobal {
		t.Error("did not find shared global fact")
	}
}
