//nolint:testpackage // intentionally uses unexported runner RAG helpers
package app

import (
	"context"
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/philippgille/chromem-go"

	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/memory"
	"github.com/allthingscode/gobot/internal/memory/vector"
)

type deterministicRAGEmbedder struct{}

func (deterministicRAGEmbedder) Embed(_ context.Context, text string) ([]float32, error) {
	vec := make([]float32, 8)
	for i, r := range text {
		vec[i%len(vec)] += float32((int(r)%17)+1) / 17.0
	}
	return vec, nil
}

func TestRunner_BuildSystemPrompt_UsesHybridRAGWithVectorDependencies(t *testing.T) { //nolint:paralleltest // Uses package-level hybrid search seam.
	ctx := context.Background()
	sessionKey := "hybrid-session"
	memStore, vecStore := newRAGTestStores(t)
	embedProv := deterministicRAGEmbedder{}
	seedVectorFact(t, ctx, vecStore, embedProv, sessionKey, "vector-only fact: project codename is atlas")
	seedFTSFact(t, memStore, sessionKey, "fts-only fact about atlas")

	runner := &AgentRunner{
		SystemPrompt: basePrompt,
		Cfg:          vectorRAGConfig(),
		VecStore:     vecStore,
		EmbedProv:    embedProv,
	}

	prompt := runner.buildSystemPrompt(ctx, sessionKey, userMessages("what is the atlas project codename?"), memStore)

	assertContains(t, prompt, "### RETRIEVED HISTORICAL CONTEXT:")
	assertContains(t, prompt, "vector-only fact: project codename is atlas")
	assertContains(t, prompt, basePrompt)
	if strings.Index(prompt, "### RETRIEVED HISTORICAL CONTEXT:") > strings.Index(prompt, basePrompt) {
		t.Fatalf("RAG block should be injected before base prompt, got %q", prompt)
	}
}

func TestRunner_GetRagBlock_SelectsHybridPathWhenAvailable(t *testing.T) { //nolint:paralleltest // Replaces package-level hybrid search seam.
	ctx := context.Background()
	sessionKey := "selection-session"
	memStore, vecStore := newRAGTestStores(t)
	embedProv := deterministicRAGEmbedder{}
	seedVectorFact(t, ctx, vecStore, embedProv, sessionKey, "hybrid selected fact")

	calls := 0
	replaceHybridRagSearch(t, func(ctx context.Context, fts ragMemorySearcher, vec *vector.Store, embed vector.EmbeddingProvider, query, gotSession string, limit int) ([]vector.HybridResult, error) {
		calls++
		if gotSession != sessionKey {
			t.Fatalf("session key = %q, want %q", gotSession, sessionKey)
		}
		return vector.HybridSearch(ctx, fts, vec, embed, query, gotSession, limit)
	})

	runner := &AgentRunner{
		Cfg:       vectorRAGConfig(),
		VecStore:  vecStore,
		EmbedProv: embedProv,
	}

	block := runner.getRagBlock(ctx, sessionKey, "tell me the selected hybrid fact", memStore)
	if calls != 1 {
		t.Fatalf("hybrid search calls = %d, want 1", calls)
	}
	assertContains(t, block, "hybrid selected fact")
}

func TestRunner_BuildSystemPrompt_HybridFailureFallsBackToFTS(t *testing.T) { //nolint:paralleltest // Replaces package-level hybrid search seam.
	ctx := context.Background()
	sessionKey := "fallback-session"
	memStore, vecStore := newRAGTestStores(t)
	seedFTSFact(t, memStore, sessionKey, "fts fallback fact about invoices status")

	replaceHybridRagSearch(t, func(context.Context, ragMemorySearcher, *vector.Store, vector.EmbeddingProvider, string, string, int) ([]vector.HybridResult, error) {
		return nil, errors.New("forced hybrid failure")
	})

	runner := &AgentRunner{
		SystemPrompt: basePrompt,
		Cfg:          vectorRAGConfig(),
		VecStore:     vecStore,
		EmbedProv:    deterministicRAGEmbedder{},
	}

	prompt := runner.buildSystemPrompt(ctx, sessionKey, userMessages("invoices status"), memStore)

	assertContains(t, prompt, "fts fallback fact about invoices status")
	assertContains(t, prompt, basePrompt)
}

func replaceHybridRagSearch(t *testing.T, fn func(context.Context, ragMemorySearcher, *vector.Store, vector.EmbeddingProvider, string, string, int) ([]vector.HybridResult, error)) {
	t.Helper()
	previous := runHybridRagSearch
	runHybridRagSearch = func(ctx context.Context, fts ragMemorySearcher, vec *vector.Store, embed vector.EmbeddingProvider, query, sessionKey string, limit int) ([]vector.HybridResult, error) {
		return fn(ctx, fts, vec, embed, query, sessionKey, limit)
	}
	t.Cleanup(func() {
		runHybridRagSearch = previous
	})
}

func newRAGTestStores(t *testing.T) (*memory.MemoryStore, *vector.Store) {
	t.Helper()
	dir := t.TempDir()
	memStore, err := memory.NewMemoryStore(filepath.Join(dir, "memory"))
	if err != nil {
		t.Fatalf("NewMemoryStore: %v", err)
	}
	t.Cleanup(func() {
		_ = memStore.Close()
	})

	vecStore, err := vector.NewStore(filepath.Join(dir, "vectors", "vectors.db"))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	t.Cleanup(func() {
		_ = vecStore.Close()
	})

	return memStore, vecStore
}

func seedVectorFact(t *testing.T, ctx context.Context, store *vector.Store, embedProv vector.EmbeddingProvider, sessionKey, content string) {
	t.Helper()
	doc := chromem.Document{
		ID:      "vec-" + sessionKey,
		Content: content,
		Metadata: map[string]string{
			"namespace":  "session:" + sessionKey,
			"timestamp":  time.Now().UTC().Format(time.RFC3339),
			"importance": "5",
		},
	}
	embedFunc := func(ctx context.Context, text string) ([]float32, error) {
		return embedProv.Embed(ctx, text)
	}
	if err := store.AddDocument(ctx, "memory_facts", doc, embedFunc); err != nil {
		t.Fatalf("AddDocument: %v", err)
	}
}

func seedFTSFact(t *testing.T, store *memory.MemoryStore, sessionKey, content string) {
	t.Helper()
	if err := store.Index("session:"+sessionKey, content); err != nil {
		t.Fatalf("Index: %v", err)
	}
}

func vectorRAGConfig() *config.Config {
	cfg := &config.Config{}
	cfg.Runtime.VectorSearchEnabled = true
	return cfg
}

func userMessages(text string) []agentctx.StrategicMessage {
	return []agentctx.StrategicMessage{
		{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: &text}},
	}
}

func assertContains(t *testing.T, got, want string) {
	t.Helper()
	if !strings.Contains(got, want) {
		t.Fatalf("expected %q to contain %q", got, want)
	}
}
