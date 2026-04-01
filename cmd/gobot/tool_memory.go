package main

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/allthingscode/gobot/internal/memory"
	"github.com/allthingscode/gobot/internal/provider"
)

const searchMemoryToolName = "search_memory"

// memorySearcher is the subset of *memory.MemoryStore used by SearchMemoryTool.
// Defined as an interface so tests can supply a mock.
type memorySearcher interface {
	Search(query string, limit int) ([]map[string]any, error)
}

// SearchMemoryTool implements Tool and queries the FTS5 long-term memory store.
type SearchMemoryTool struct {
	store memorySearcher
}

// newSearchMemoryTool returns a SearchMemoryTool backed by store.
func newSearchMemoryTool(store *memory.MemoryStore) *SearchMemoryTool {
	return &SearchMemoryTool{store: store}
}

func (t *SearchMemoryTool) Name() string { return searchMemoryToolName }

func (t *SearchMemoryTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        searchMemoryToolName,
		Description: "Search your long-term memory for facts, past decisions, or context from previous sessions. Use this when you need to recall specific information that may not be in the current conversation.",
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"query": map[string]any{
					"type":        "string",
					"description": "Keywords or a natural language query describing what to recall.",
				},
				"limit": map[string]any{
					"type":        "integer",
					"description": "Maximum number of results to return. Defaults to 5.",
				},
			},
			"required": []string{"query"},
		},
	}
}

// Execute searches the memory store and returns results as a JSON string.
// If no results are found, returns a plain-text message saying so.
func (t *SearchMemoryTool) Execute(_ context.Context, _ string, args map[string]any) (string, error) {
	query, _ := args["query"].(string)
	if query == "" {
		return "", fmt.Errorf("search_memory: query is required")
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

	results, err := t.store.Search(query, limit)
	if err != nil {
		return "", fmt.Errorf("search_memory: %w", err)
	}
	if len(results) == 0 {
		return "No matching memories found.", nil
	}

	data, err := json.Marshal(results)
	if err != nil {
		return "", fmt.Errorf("search_memory: marshal: %w", err)
	}
	return string(data), nil
}
