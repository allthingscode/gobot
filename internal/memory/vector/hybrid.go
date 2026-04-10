package vector

import (
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
