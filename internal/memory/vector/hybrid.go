package vector

import (
	"context"
	"fmt"
	"sort"
	"time"

	"github.com/philippgille/chromem-go"
)

// HybridResult represents a merged search result.
type HybridResult struct {
	ID        string
	Content   string
	Timestamp string
	Score     float64
}

// FTSResult models the output from MemoryStore.Search.
type FTSResult struct {
	ID        string
	Content   string
	Timestamp string
}

// memorySearcher defines the subset of MemoryStore needed for hybrid search.
type memorySearcher interface {
	Search(query string, limit int) ([]map[string]any, error)
}

// HybridSearch orchestrates a keyword search (FTS5) and a semantic search (vector),
// merging them using Reciprocal Rank Fusion (RRF).
func HybridSearch(ctx context.Context, fts memorySearcher, vec *Store, embedProv EmbeddingProvider, query string, limit int) ([]HybridResult, error) {
	if limit <= 0 {
		limit = 5
	}

	// 1. FTS5 Keyword Search
	ftsResultsRaw, err := fts.Search(query, limit*2) // fetch more for re-ranking
	if err != nil {
		return nil, fmt.Errorf("fts search: %w", err)
	}

	var ftsResults []FTSResult
	for _, res := range ftsResultsRaw {
		id, _ := res["session_key"].(string)
		content, _ := res["content"].(string)
		timestamp, _ := res["timestamp"].(string)
		ftsResults = append(ftsResults, FTSResult{
			ID:        id,
			Content:   content,
			Timestamp: timestamp,
		})
	}

	// 2. Vector Semantic Search
	embedFunc := func(c context.Context, text string) ([]float32, error) {
		return embedProv.Embed(c, text)
	}

	// For memory facts, we use a 'memory_facts' collection
	vecResults, err := vec.Search(ctx, "memory_facts", query, limit*2, embedFunc)
	if err != nil {
		return nil, fmt.Errorf("vector search: %w", err)
	}

	// 3. Hybrid RRF Merge
	merged := MergeResults(ftsResults, vecResults, 60)

	if len(merged) > limit {
		merged = merged[:limit]
	}

	return merged, nil
}

// MergeResults applies Reciprocal Rank Fusion (RRF) to combine keyword and semantic search results.
// k is a constant typically set to 60.
func MergeResults(ftsResults []FTSResult, vecResults []chromem.Result, k int) []HybridResult {
	if k <= 0 {
		k = 60
	}

	scores := make(map[string]float64)
	contentMap := make(map[string]string)
	timestampMap := make(map[string]string)

	// Process FTS results
	for rank, res := range ftsResults {
		score := 1.0 / float64(k+rank+1) // rank is 0-indexed
		scores[res.ID] += score
		contentMap[res.ID] = res.Content
		timestampMap[res.ID] = res.Timestamp
	}

	// Process Vector results
	for rank, res := range vecResults {
		score := 1.0 / float64(k+rank+1)
		scores[res.ID] += score
		contentMap[res.ID] = res.Content
		if ts, ok := res.Metadata["timestamp"]; ok {
			timestampMap[res.ID] = ts
		} else if timestampMap[res.ID] == "" {
			timestampMap[res.ID] = time.Now().UTC().Format(time.RFC3339) // fallback
		}
	}

	var merged []HybridResult
	for id, score := range scores {
		merged = append(merged, HybridResult{
			ID:        id,
			Content:   contentMap[id],
			Timestamp: timestampMap[id],
			Score:     score,
		})
	}

	// Sort by score descending
	sort.Slice(merged, func(i, j int) bool {
		return merged[i].Score > merged[j].Score
	})

	return merged
}
