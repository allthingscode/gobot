package app

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/allthingscode/gobot/internal/agent"

	"github.com/allthingscode/gobot/internal/memory/vector"
	"github.com/allthingscode/gobot/internal/observability"
	"github.com/allthingscode/gobot/internal/provider"
	"github.com/philippgille/chromem-go"
)

const searchDocsToolName = "search_docs"

// MemorySearcher is the minimal interface needed for hybrid retrieval.
type MemorySearcher interface {
	Search(ctx context.Context, query, namespace string, limit int) ([]map[string]any, error)
}

type SearchDocsTool struct {
	memStore  MemorySearcher
	vecStore  *vector.Store
	embedProv vector.EmbeddingProvider
	tracer    *observability.DispatchTracer
}

func newSearchDocsTool(memStore MemorySearcher, vecStore *vector.Store, embedProv vector.EmbeddingProvider, tracer *observability.DispatchTracer) *SearchDocsTool {
	return &SearchDocsTool{
		memStore:  memStore,
		vecStore:  vecStore,
		embedProv: embedProv,
		tracer:    tracer,
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

	var merged []vector.HybridResult
	var err error
	var mappedFTS []vector.FTSResult

	if t.tracer != nil {
		err = t.tracer.TraceMemorySearch(ctx, "hybrid", func(ctx context.Context) error {
			var errInner error
			mappedFTS, errInner = t.searchFTS(ctx, query, limit)
			if errInner != nil {
				return fmt.Errorf("fts search: %w", errInner)
			}

			var vecResultsInner []chromem.Result
			vecResultsInner, errInner = t.searchVectors(ctx, query, limit)
			if errInner != nil {
				return fmt.Errorf("vector search: %w", errInner)
			}

			merged = vector.MergeResults(mappedFTS, vecResultsInner, 60)
			return nil
		})
		if err != nil {
			return "", fmt.Errorf("hybrid search trace: %w", err)
		}
	} else {
		var err2 error
		mappedFTS, err2 = t.searchFTS(ctx, query, limit)
		if err2 != nil {
			return "", fmt.Errorf("fts search: %w", err2)
		}

		var vecResults []chromem.Result
		vecResults, err2 = t.searchVectors(ctx, query, limit)
		if err2 != nil {
			return "", fmt.Errorf("vector search: %w", err2)
		}

		merged = vector.MergeResults(mappedFTS, vecResults, 60)
	}

	if err != nil {
		return "", fmt.Errorf("search_docs execution: %w", err)
	}

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

func (t *SearchDocsTool) searchFTS(ctx context.Context, query string, limit int) ([]vector.FTSResult, error) {
	ftsResults, err := t.memStore.Search(ctx, query, "", limit*2)
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
	res, err := t.vecStore.Search(ctx, "workspace_docs", query, limit*2, nil, embedFunc)
	if err != nil {
		return nil, fmt.Errorf("search vectors: %w", err)
	}
	return res, nil
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
