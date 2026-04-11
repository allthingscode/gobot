package main

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/allthingscode/gobot/internal/memory"
	"github.com/allthingscode/gobot/internal/memory/vector"
	"github.com/allthingscode/gobot/internal/provider"
)

const searchDocsToolName = "search_docs"

// SearchDocsTool implements Tool and performs hybrid retrieval on workspace docs.
type SearchDocsTool struct {
	memStore  memorySearcher // reusing from tool_memory.go
	vecStore  *vector.Store
	embedProv vector.EmbeddingProvider
}

// newSearchDocsTool creates a new SearchDocsTool.
func newSearchDocsTool(memStore *memory.MemoryStore, vecStore *vector.Store, embedProv vector.EmbeddingProvider) *SearchDocsTool {
	return &SearchDocsTool{
		memStore:  memStore,
		vecStore:  vecStore,
		embedProv: embedProv,
	}
}

func (t *SearchDocsTool) Name() string { return searchDocsToolName }

func (t *SearchDocsTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        searchDocsToolName,
		Description: "Searches the project workspace Markdown files for architectural notes, project specifications, and historical context using semantic hybrid retrieval (keyword + vector).",
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"query": map[string]any{
					"type":        "string",
					"description": "The natural language query or keywords to search for.",
				},
				"limit": map[string]any{
					"type":        "integer",
					"description": "Optional maximum number of results to return. Defaults to 5.",
				},
			},
			"required": []string{"query"},
		},
	}
}

func (t *SearchDocsTool) Execute(ctx context.Context, sessionKey, userID string, args map[string]any) (string, error) {
	query, _ := args["query"].(string)
	if query == "" {
		return "", fmt.Errorf("search_docs: query is required")
	}

	limit := 5
	if v, ok := args["limit"]; ok {
		switch n := v.(type) {
		case float64:
			limit = int(n)
		case int:
			limit = n
		case int64:
			limit = int(n)
		}
	}
	if limit <= 0 {
		limit = 5
	}

	// 1. FTS5 Keyword Search (searches agent conversation memory)
	ftsResults, err := t.memStore.Search(query, "", limit*2) // fetch more for re-ranking
	if err != nil {
		return "", fmt.Errorf("fts search: %w", err)
	}

	var mappedFTS []vector.FTSResult
	for _, res := range ftsResults {
		id, _ := res["namespace"].(string)
		content, _ := res["content"].(string)
		timestamp, _ := res["timestamp"].(string)
		mappedFTS = append(mappedFTS, vector.FTSResult{
			ID:        id,
			Content:   content,
			Timestamp: timestamp,
		})
	}

	// 2. Vector Semantic Search (searches workspace documents)
	embedFunc := func(c context.Context, text string) ([]float32, error) {
		return t.embedProv.Embed(c, text)
	}

	// F-025 specifies 'workspace_docs' collection in vector store
	vecResults, err := t.vecStore.Search(ctx, "workspace_docs", query, limit*2, nil, embedFunc)
	if err != nil {
		return "", fmt.Errorf("vector search: %w", err)
	}

	// 3. Hybrid RRF Merge
	merged := vector.MergeResults(mappedFTS, vecResults, 60)

	if len(merged) == 0 {
		return "No matching documents found in the workspace or memory.", nil
	}

	if len(merged) > limit {
		merged = merged[:limit]
	}

	data, err := json.Marshal(merged)
	if err != nil {
		return "", fmt.Errorf("marshal results: %w", err)
	}

	return string(data), nil
}
