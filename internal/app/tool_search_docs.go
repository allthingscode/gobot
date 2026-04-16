package app

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/allthingscode/gobot/internal/agent"

	"github.com/allthingscode/gobot/internal/memory/vector"
	"github.com/allthingscode/gobot/internal/provider"
	"github.com/philippgille/chromem-go"
)

const searchDocsToolName = "search_docs"

// MemorySearcher is the minimal interface needed for hybrid retrieval.
type MemorySearcher interface {
	Search(query, namespace string, limit int) ([]map[string]any, error)
}

type SearchDocsTool struct {
	memStore  MemorySearcher
	vecStore  *vector.Store
	embedProv vector.EmbeddingProvider
}

func newSearchDocsTool(memStore MemorySearcher, vecStore *vector.Store, embedProv vector.EmbeddingProvider) *SearchDocsTool {
	return &SearchDocsTool{
		memStore:  memStore,
		vecStore:  vecStore,
		embedProv: embedProv,
	}
}

func (t *SearchDocsTool) Name() string { return searchDocsToolName }

type searchDocsArgs struct {
	Query string `json:"query" schema:"The natural language query or keywords to search for."`
	Limit int    `json:"limit,omitempty" schema:"Optional maximum number of results to return. Defaults to 5."`
}

func (t *SearchDocsTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        searchDocsToolName,
		Description: "Searches the project workspace Markdown files for architectural notes, project specifications, and historical context using semantic hybrid retrieval (keyword + vector).",
		Parameters:  agent.DeriveSchema(searchDocsArgs{}),
	}
}

func (t *SearchDocsTool) Execute(ctx context.Context, sessionKey, userID string, args map[string]any) (string, error) {
	query, _ := args["query"].(string)
	if query == "" {
		return "", fmt.Errorf("search_docs: query is required")
	}

	limit := parseLimit(args["limit"])

	mappedFTS, err := t.searchFTS(query, limit)
	if err != nil {
		return "", err
	}

	vecResults, err := t.searchVectors(ctx, query, limit)
	if err != nil {
		return "", err
	}

	merged := vector.MergeResults(mappedFTS, vecResults, 60)

	return formatResults(merged, limit)
}

func parseLimit(arg any) int {
	limit := 5
	switch v := arg.(type) {
	case float64:
		limit = int(v)
	case int:
		limit = v
	case int64:
		limit = int(v)
	}
	if limit <= 0 {
		limit = 5
	}
	return limit
}

func (t *SearchDocsTool) searchFTS(query string, limit int) ([]vector.FTSResult, error) {
	ftsResults, err := t.memStore.Search(query, "", limit*2)
	if err != nil {
		return nil, fmt.Errorf("fts search: %w", err)
	}

	mappedFTS := make([]vector.FTSResult, 0, len(ftsResults))
	for _, res := range ftsResults {
		id, _ := res["namespace"].(string)
		content, _ := res["content"].(string)
		timestamp, _ := res["timestamp"].(string)
		mappedFTS = append(mappedFTS, vector.FTSResult{ID: id, Content: content, Timestamp: timestamp})
	}
	return mappedFTS, nil
}

func (t *SearchDocsTool) searchVectors(ctx context.Context, query string, limit int) ([]chromem.Result, error) {
	embedFunc := func(c context.Context, text string) ([]float32, error) {
		return t.embedProv.Embed(c, text)
	}
	return t.vecStore.Search(ctx, "workspace_docs", query, limit*2, nil, embedFunc)
}

func formatResults(merged []vector.HybridResult, limit int) (string, error) {
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
