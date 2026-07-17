package app

import (
	"context"
	"fmt"
	"log/slog"

	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/memory"
	"github.com/allthingscode/gobot/internal/memory/vector"
)

type ragMemorySearcher interface {
	Search(context.Context, string, string, int) ([]map[string]any, error)
}

type hybridRagSearchFunc func(context.Context, ragMemorySearcher, *vector.Store, vector.EmbeddingProvider, string, string, int) ([]vector.HybridResult, error)

// runHybridRagSearch is a package-private seam for app-level runner tests.
//
//nolint:gochecknoglobals // Package-private test seam; production default delegates to vector.HybridSearch.
var runHybridRagSearch hybridRagSearchFunc = func(ctx context.Context, fts ragMemorySearcher, vec *vector.Store, embedProv vector.EmbeddingProvider, query, sessionKey string, limit int) ([]vector.HybridResult, error) {
	return vector.HybridSearch(ctx, fts, vec, embedProv, query, sessionKey, limit)
}

func (r *AgentRunner) buildSystemPrompt(ctx context.Context, sessionKey string, messages []agentctx.StrategicMessage, memStore *memory.MemoryStore) string {
	sysPrompt := r.SystemPrompt
	if memStore != nil {
		if userText := LastUserText(messages); !memory.ShouldSkipRAG(userText) {
			ragBlock := r.getRagBlock(ctx, sessionKey, userText, memStore)
			if ragBlock != "" {
				if sysPrompt != "" {
					sysPrompt = ragBlock + "\n\n" + sysPrompt
				} else {
					sysPrompt = ragBlock
				}
			}
		}
	}

	if r.Hooks != nil {
		sysPrompt = r.Hooks.RunPrePrompt(ctx, sysPrompt)
	}
	return sysPrompt
}

func (r *AgentRunner) getRagBlock(ctx context.Context, sessionKey, userText string, memStore *memory.MemoryStore) string {
	var filtered []map[string]any

	if r.Cfg.VectorSearchEnabled() && r.VecStore != nil && r.EmbedProv != nil {
		filtered = r.hybridRagSearch(ctx, sessionKey, userText, memStore)
	} else {
		filtered = r.ftsSearch(ctx, userText, sessionKey, memStore)
	}

	block, n := memory.FormatRAGBlock(filtered)
	if n > 0 {
		slog.Debug("runner: injecting RAG context", "entries", n)
		return block
	}
	return ""
}

func (r *AgentRunner) hybridRagSearch(ctx context.Context, sessionKey, userText string, memStore *memory.MemoryStore) []map[string]any {
	var hybridResults []vector.HybridResult
	var err error
	if r.Tracer != nil {
		err = r.Tracer.TraceMemorySearch(ctx, "hybrid", func(ctx context.Context) error {
			var err2 error
			hybridResults, err2 = runHybridRagSearch(ctx, memStore, r.VecStore, r.EmbedProv, userText, sessionKey, 5)
			if err2 != nil {
				return fmt.Errorf("hybrid search: %w", err2)
			}
			return nil
		})
	} else {
		var err2 error
		hybridResults, err2 = runHybridRagSearch(ctx, memStore, r.VecStore, r.EmbedProv, userText, sessionKey, 5)
		if err2 != nil {
			err = fmt.Errorf("hybrid search: %w", err2)
		}
	}

	if err == nil {
		filtered := make([]map[string]any, 0, len(hybridResults))
		for _, res := range hybridResults {
			filtered = append(filtered, map[string]any{
				"content": res.Content,
				"score":   res.Score,
			})
		}
		return filtered
	}

	slog.Warn("runner: hybrid RAG search failed, falling back to FTS5", "err", err)
	return r.ftsSearch(ctx, userText, sessionKey, memStore)
}

func (r *AgentRunner) ftsSearch(ctx context.Context, userText, sessionKey string, memStore *memory.MemoryStore) []map[string]any {
	var results []map[string]any
	var err error

	if r.Tracer != nil {
		err = r.Tracer.TraceMemorySearch(ctx, "fts", func(ctx context.Context) error {
			var err2 error
			results, err2 = memStore.Search(ctx, userText, sessionKey, 10)
			if err2 != nil {
				return fmt.Errorf("fts search: %w", err2)
			}
			return nil
		})
	} else {
		results, err = memStore.Search(ctx, userText, sessionKey, 10)
	}

	if err != nil {
		slog.Error("runner: FTS search failed", "err", err, "session", sessionKey)
		return nil
	}

	if len(results) > 0 {
		return memory.FilterRAGResults(results, 0.0)
	}
	return nil
}
