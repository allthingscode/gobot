package app

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/observability"
	"github.com/allthingscode/gobot/internal/provider"
)

// MemoryStore is the interface required by MemoryTool.
type MemoryStore interface {
	Index(namespace, content string) error
	Search(ctx context.Context, query, namespace string, limit int) ([]map[string]any, error)
	Close() error
	Rebuild(sessionDir string) (int, error)
}

// -- MemoryTool ----------------------------------------------------------------

const memoryToolName = "memory"

// MemoryTool allows the agent to read and search its long-term memory index.
type MemoryTool struct {
	store  MemoryStore
	tracer *observability.DispatchTracer
}

// NewSearchMemoryTool creates a new MemoryTool instance.
func NewSearchMemoryTool(store MemoryStore, tracer *observability.DispatchTracer) *MemoryTool {
	return &MemoryTool{store: store, tracer: tracer}
}

type memoryArgs struct {
	Query string `json:"query" schema:"The search query to look for in long-term memory."`
}

// Name returns the tool name.
func (t *MemoryTool) Name() string { return memoryToolName }

// Declaration returns the tool declaration for the provider.
func (t *MemoryTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        memoryToolName,
		Description: "Search the agent's long-term memory (indexed from past sessions). Returns the most relevant historical snippets.",
		Parameters:  agent.DeriveSchema(memoryArgs{}),
	}
}

// Execute runs the memory search.
func (t *MemoryTool) Execute(ctx context.Context, sessionKey, _ string, args map[string]any) (string, error) {
	if t.store == nil {
		return "Long-term memory is currently unavailable.", nil
	}

	query, _ := args["query"].(string)
	if query == "" {
		return "", fmt.Errorf("memory: query is required")
	}

	var results []map[string]any
	var err error
	if t.tracer != nil {
		err = t.tracer.TraceMemorySearch(ctx, "fts", func(ctx context.Context) error {
			var err2 error
			results, err2 = t.store.Search(ctx, query, sessionKey, 5)
			if err2 != nil {
				return fmt.Errorf("fts search: %w", err2)
			}
			return nil
		})
	} else {
		var err2 error
		results, err2 = t.store.Search(ctx, query, sessionKey, 5)
		if err2 != nil {
			err = fmt.Errorf("fts search: %w", err2)
		}
	}
	if err != nil {
		return "", fmt.Errorf("memory: %w", err)
	}

	if len(results) == 0 {
		return "No relevant memories found.", nil
	}

	b, _ := json.Marshal(results)
	return string(b), nil
}
