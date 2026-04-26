//nolint:testpackage // requires unexported vector internals for testing
package vector

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/philippgille/chromem-go"
)

type mockSearcher struct {
	results []map[string]any
}

func (m *mockSearcher) Search(ctx context.Context, query, sessionKey string, limit int) ([]map[string]any, error) {
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

func TestMergeResults_ImportanceRanking(t *testing.T) {
	t.Parallel()
	// Two vector results at the same rank (rank 0 each, no FTS results).
	// highImp has importance=5, lowImp has importance=1.
	// After importance blending, highImp must score higher.
	fts := []FTSResult{}
	vec := []chromem.Result{
		{ID: "lowImp", Content: "low importance fact", Metadata: map[string]string{
			"timestamp":  "2026-04-10T10:00:00Z",
			"importance": "1",
			"namespace":  "session:s",
		}},
		{ID: "highImp", Content: "high importance fact", Metadata: map[string]string{
			"timestamp":  "2026-04-10T10:00:00Z",
			"importance": "5",
			"namespace":  "session:s",
		}},
	}

	merged := MergeResults(fts, vec, 60)

	if len(merged) != 2 {
		t.Fatalf("expected 2 results, got %d", len(merged))
	}
	if merged[0].ID != "highImp" {
		t.Errorf("expected highImp first (importance=5), got %s (score=%.4f); lowImp score=%.4f",
			merged[0].ID, merged[0].Score, merged[1].Score)
	}
}

func TestMergeResults_MissingImportanceDefaultsTo3(t *testing.T) {
	t.Parallel()
	fts := []FTSResult{}
	vec := []chromem.Result{
		{ID: "noMeta", Content: "no metadata", Metadata: map[string]string{}},
	}
	merged := MergeResults(fts, vec, 60)
	if len(merged) != 1 {
		t.Fatalf("expected 1 result, got %d", len(merged))
	}
	// Score should be rrfScore * (0.5 + 0.5*(3/5)) = rrfScore * 0.8
	rrfScore := 1.0 / float64(60+0+1)
	wantScore := rrfScore * (rrfBlendWeight + importanceBlendWeight*(float64(defaultImportance)/5.0))
	if abs(merged[0].Score-wantScore) > 1e-7 {
		t.Errorf("score = %.9f, want %.9f", merged[0].Score, wantScore)
	}
}

func abs(x float64) float64 {
	if x < 0 {
		return -x
	}
	return x
}

//nolint:cyclop // test complexity justified by isolation verification
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

func TestApplyMMR(t *testing.T) {
	t.Parallel()
	// Test data: doc1 and doc2 are identical (high similarity to each other)
	// doc3 is different.
	// Query similarity: doc1=0.9, doc2=0.85, doc3=0.7.
	// MMR should pick doc1 and then doc3 (because doc2 is redundant with doc1).
	results := []chromem.Result{
		{ID: "doc1", Similarity: 0.9, Embedding: []float32{1.0, 0.0}},
		{ID: "doc2", Similarity: 0.85, Embedding: []float32{0.99, 0.01}}, // very similar to doc1
		{ID: "doc3", Similarity: 0.7, Embedding: []float32{0.0, 1.0}},   // orthogonal to doc1
	}

	selected := applyMMR(results, 0.5, 2)
	if len(selected) != 2 {
		t.Fatalf("expected 2 selected results, got %d", len(selected))
	}
	if selected[0].ID != "doc1" {
		t.Errorf("expected first doc to be doc1, got %s", selected[0].ID)
	}
	if selected[1].ID != "doc3" {
		t.Errorf("expected second doc to be doc3 (diversity), got %s", selected[1].ID)
	}
}

func TestComputeTimeDecay(t *testing.T) {
	t.Parallel()
	now := time.Now().UTC()
	
	tests := []struct {
		name      string
		timestamp string
		wantMin   float64
		wantMax   float64
	}{
		{
			name:      "recent",
			timestamp: now.Format(time.RFC3339),
			wantMin:   0.99,
			wantMax:   1.0,
		},
		{
			name:      "30 days ago (one half-life)",
			timestamp: now.Add(-30 * 24 * time.Hour).Format(time.RFC3339),
			wantMin:   0.49,
			wantMax:   0.51,
		},
		{
			name:      "60 days ago (two half-lives)",
			timestamp: now.Add(-60 * 24 * time.Hour).Format(time.RFC3339),
			wantMin:   0.24,
			wantMax:   0.26,
		},
		{
			name:      "invalid timestamp",
			timestamp: "invalid",
			wantMin:   1.0,
			wantMax:   1.0,
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got := computeTimeDecay(tt.timestamp)
			if got < tt.wantMin || got > tt.wantMax {
				t.Errorf("computeTimeDecay() = %f, want range [%f, %f]", got, tt.wantMin, tt.wantMax)
			}
		})
	}
}
