package vector

import (
	"context"
	"fmt"
	"math"
	"sort"
	"strconv"
	"time"

	"github.com/philippgille/chromem-go"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"
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
	Search(ctx context.Context, query, sessionKey string, limit int) ([]map[string]any, error)
}

// HybridSearch orchestrates a keyword search (FTS5) and a semantic search (vector),
// merging them using Reciprocal Rank Fusion (RRF).
func HybridSearch(ctx context.Context, fts memorySearcher, vec *Store, embedProv EmbeddingProvider, query, sessionKey string, limit int) ([]HybridResult, error) {
	ctx, span := otel.Tracer("gobot-memory").Start(ctx, "vector.HybridSearch",
		trace.WithAttributes(attribute.Int("memory.limit", limit)),
	)
	defer span.End()

	if limit <= 0 {
		limit = 5
	}

	// 1. FTS5 Keyword Search
	ftsResultsRaw, err := fts.Search(ctx, query, sessionKey, limit*2) // fetch more for re-ranking
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
		return nil, fmt.Errorf("fts search: %w", err)
	}

	ftsResults := make([]FTSResult, 0, len(ftsResultsRaw))
	for _, res := range ftsResultsRaw {
		id, _ := res["namespace"].(string)
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

	// For memory facts, we use a 'memory_facts' collection.
	// Search with a larger limit to allow for in-memory filtering.
	rawVecResults, err := vec.Search(ctx, "memory_facts", query, limit*4, nil, embedFunc)
	if err != nil {
		return nil, fmt.Errorf("vector search: %w", err)
	}

	// Filter by namespace in memory to preserve session isolation.
	var vecResults []chromem.Result
	sessionNamespace := "session:" + sessionKey
	for _, res := range rawVecResults {
		ns := res.Metadata["namespace"]
		if ns == sessionNamespace || ns == "global" {
			vecResults = append(vecResults, res)
		}
	}
	
	// Apply MMR to re-rank and downsample to limit*2
	vecResults = applyMMR(vecResults, 0.7, limit*2)

	// 3. Hybrid RRF Merge
	merged := MergeResults(ftsResults, vecResults, 60)

	if len(merged) > limit {
		merged = merged[:limit]
	}

	span.SetAttributes(attribute.Int("memory.results_count", len(merged)))
	return merged, nil
}

// Importance blend constants. rrfBlendWeight + importanceBlendWeight must equal 1.0.
// A 50/50 split means importance can suppress low-signal facts by up to 40% (importance=1 → 0.6×)
// without over-riding strong RRF rank signal from high-importance facts (importance=5 → 1.0×).
const (
	rrfBlendWeight        = 0.5 // weight given to RRF rank score
	importanceBlendWeight = 0.5 // weight given to normalised importance score
	defaultImportance     = 3   // assigned to FTS results which do not carry importance metadata
)

// importanceFromMetadata extracts importance from document metadata, defaulting to defaultImportance.
func importanceFromMetadata(meta map[string]string) int {
	if s, ok := meta["importance"]; ok {
		if v, err := strconv.Atoi(s); err == nil && v >= 1 && v <= 5 {
			return v
		}
	}
	return defaultImportance
}

// MergeResults applies Reciprocal Rank Fusion (RRF) to combine keyword and semantic search results,
// then adjusts final scores by importance metadata so high-signal facts rank above equal-RRF peers.
// k is a constant typically set to 60.
func MergeResults(ftsResults []FTSResult, vecResults []chromem.Result, k int) []HybridResult {
	if k <= 0 {
		k = 60
	}

	scores := make(map[string]float64)
	contentMap := make(map[string]string)
	timestampMap := make(map[string]string)
	importanceMap := make(map[string]int)

	// Process FTS results — importance defaults to 3 (no metadata available).
	for rank, res := range ftsResults {
		scores[res.ID] += 1.0 / float64(k+rank+1)
		contentMap[res.ID] = res.Content
		timestampMap[res.ID] = res.Timestamp
		if _, seen := importanceMap[res.ID]; !seen {
			importanceMap[res.ID] = defaultImportance
		}
	}

	// Process Vector results — parse importance from document metadata.
	// Vector importance wins over FTS default when the same ID appears in both.
	for rank, res := range vecResults {
		scores[res.ID] += 1.0 / float64(k+rank+1)
		contentMap[res.ID] = res.Content
		if ts, ok := res.Metadata["timestamp"]; ok {
			timestampMap[res.ID] = ts
		} else if timestampMap[res.ID] == "" {
			timestampMap[res.ID] = time.Now().UTC().Format(time.RFC3339)
		}
		importanceMap[res.ID] = importanceFromMetadata(res.Metadata)
	}

	merged := make([]HybridResult, 0, len(scores))
	for id, rrfScore := range scores {
		decay := computeTimeDecay(timestampMap[id])
		normImp := float64(importanceMap[id]) / 5.0 // normalise to [0.2, 1.0]
		merged = append(merged, HybridResult{
			ID:        id,
			Content:   contentMap[id],
			Timestamp: timestampMap[id],
			Score:     rrfScore * (rrfBlendWeight + importanceBlendWeight*(normImp*decay)),
		})
	}

	sort.Slice(merged, func(i, j int) bool {
		return merged[i].Score > merged[j].Score
	})

	return merged
}

// nolint:cyclop,gocognit // MMR algorithm requires nested loops and multiple checks; splitting would reduce clarity.
func applyMMR(results []chromem.Result, lambda float32, limit int) []chromem.Result {
	if limit >= len(results) {
		limit = len(results)
	}
	if limit <= 0 || len(results) == 0 {
		return nil
	}

	var selected []chromem.Result
	var selectedIdx []int

	unselected := make([]int, len(results))
	for i := range results {
		unselected[i] = i
	}

	for len(selected) < limit && len(unselected) > 0 {
		bestIdx := -1
		var bestScore float32 = -math.MaxFloat32
		bestUnselectedIdx := -1

		for i, idx := range unselected {
			candidate := results[idx]
			sim1 := candidate.Similarity

			var maxSim2 float32 = 0
			for _, sIdx := range selectedIdx {
				sim2 := cosineSimilarity(candidate.Embedding, results[sIdx].Embedding)
				if sim2 > maxSim2 {
					maxSim2 = sim2
				}
			}

			mmrScore := lambda*sim1 - (1-lambda)*maxSim2
			if math.IsNaN(float64(mmrScore)) {
				mmrScore = 0
			}
			if mmrScore > bestScore {
				bestScore = mmrScore
				bestIdx = idx
				bestUnselectedIdx = i
			}
		}

		if bestIdx == -1 {
			bestIdx = unselected[0]
			bestUnselectedIdx = 0
		}

		selected = append(selected, results[bestIdx])
		selectedIdx = append(selectedIdx, bestIdx)
		unselected = append(unselected[:bestUnselectedIdx], unselected[bestUnselectedIdx+1:]...)
	}

	return selected
}

func cosineSimilarity(a, b []float32) float32 {
	if len(a) != len(b) || len(a) == 0 {
		return 0
	}
	var dotProduct, normA, normB float32
	for i := range a {
		dotProduct += a[i] * b[i]
		normA += a[i] * a[i]
		normB += b[i] * b[i]
	}
	if normA == 0 || normB == 0 {
		return 0
	}
	return dotProduct / float32(math.Sqrt(float64(normA))*math.Sqrt(float64(normB)))
}

const halfLifeHours = 720.0 // 30 days
func computeTimeDecay(ts string) float64 {
	t, err := time.Parse(time.RFC3339, ts)
	if err != nil {
		return 1.0 // no decay if parse fails
	}
	hours := time.Since(t).Hours()
	if hours < 0 {
		hours = 0
	}
	decayLambda := math.Ln2 / halfLifeHours
	return math.Exp(-decayLambda * hours)
}