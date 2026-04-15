package app

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/provider"
)

// MemoryStore is the interface required by MemoryTool.
type MemoryStore interface {
	Index(namespace, content string) error
	Search(query, namespace string, limit int) ([]map[string]any, error)
	Close() error
	Rebuild(sessionDir string) (int, error)
}

// -- MemoryTool ----------------------------------------------------------------

const memoryToolName = "memory"

// MemoryTool allows the agent to read and search its long-term memory index.
type MemoryTool struct {
	store MemoryStore
}

func NewSearchMemoryTool(store MemoryStore) *MemoryTool {
	return &MemoryTool{store: store}
}

type memoryArgs struct {
	Query string `json:"query" schema:"The search query to look for in long-term memory."`
}

func (t *MemoryTool) Name() string { return memoryToolName }

func (t *MemoryTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        memoryToolName,
		Description: "Search the agent's long-term memory (indexed from past sessions). Returns the most relevant historical snippets.",
		Parameters:  agent.DeriveSchema(memoryArgs{}),
	}
}

func (t *MemoryTool) Execute(_ context.Context, sessionKey, _ string, args map[string]any) (string, error) {
	if t.store == nil {
		return "Long-term memory is currently unavailable.", nil
	}

	query, _ := args["query"].(string)
	if query == "" {
		return "", fmt.Errorf("memory: query is required")
	}

	// F-071: Pass sessionKey to Search
	results, err := t.store.Search(query, sessionKey, 5)
	if err != nil {
		return "", fmt.Errorf("memory: %w", err)
	}

	if len(results) == 0 {
		return "No relevant memories found.", nil
	}

	b, _ := json.Marshal(results)
	return string(b), nil
}
