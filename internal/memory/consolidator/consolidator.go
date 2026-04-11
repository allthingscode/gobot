package consolidator

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/allthingscode/gobot/internal/memory"
	"github.com/allthingscode/gobot/internal/memory/vector"
	"github.com/allthingscode/gobot/internal/observability"
	"github.com/philippgille/chromem-go"
)

// minConsolidateLength is the minimum reply length (runes) worth consolidating.
// Short replies like "OK" or "Done." carry no long-term facts.
const minConsolidateLength = 80

// consolidationPrompt is the system prompt for the fact-extraction LLM call.
const consolidationPrompt = `You are a memory consolidation assistant. Extract key facts from the following agent reply that are worth remembering long-term — decisions made, deadlines, preferences, project details, or any specific factual information.

Return ONLY a JSON array of concise factual strings. Return an empty array [] if there are no notable facts. Do not include conversational filler, acknowledgements, or generic statements.

Example output:
["Project Alpha deadline is May 1 2026", "User prefers async status updates on Fridays", "Budget approved for Q2 at $50k"]

Agent reply to consolidate:
`

// TextRunner is the interface used by Consolidator to make a single LLM call.
// geminiRunner in cmd/gobot/runner.go implements this via RunText.
type TextRunner interface {
	RunText(ctx context.Context, sessionKey, prompt string, modelOverride string) (string, error)
}

// Consolidator extracts facts from agent replies and indexes them into the
// long-term memory store. All operations are best-effort — errors are logged
// and never propagated to the caller.
type Consolidator struct {
	runner    TextRunner
	store     *memory.MemoryStore
	vecStore  *vector.Store             // F-030: Semantic memory
	embedProv vector.EmbeddingProvider // F-030: Semantic memory
	prompt    string
	ttl       string                  // e.g., "2160h" for 90 days; empty means no cleanup
	globalTTL string                  // F-071: TTL for global namespace
	patterns  []string                // F-071: Patterns for global routing
	obs       *observability.Provider // optional observability provider
}

// New creates a Consolidator. Both runner and store must be non-nil.
// vecStore and embedProv may be nil (semantic memory disabled).
func New(runner TextRunner, store *memory.MemoryStore, vecStore *vector.Store, embedProv vector.EmbeddingProvider) *Consolidator {
	return &Consolidator{
		runner:    runner,
		store:     store,
		vecStore:  vecStore,
		embedProv: embedProv,
		prompt:    consolidationPrompt,
		ttl:       "",
		globalTTL: "",
		patterns:  nil,
		obs:       nil,
	}
}

// SetPrompt overrides the default consolidation system prompt.
func (c *Consolidator) SetPrompt(p string) {
	if p != "" {
		c.prompt = p
	}
}

// SetTTL sets the TTL for session memory cleanup (e.g., "2160h" for 90 days).
func (c *Consolidator) SetTTL(ttl string) {
	c.ttl = ttl
}

// SetGlobalTTL sets the TTL for global memory cleanup (F-071).
func (c *Consolidator) SetGlobalTTL(ttl string) {
	c.globalTTL = ttl
}

// SetGlobalPatterns sets the patterns used to route facts to the global namespace (F-071).
func (c *Consolidator) SetGlobalPatterns(patterns []string) {
	c.patterns = patterns
}

// SetObservability sets the observability provider for metrics recording.
func (c *Consolidator) SetObservability(obs *observability.Provider) {
	c.obs = obs
}

// ConsolidateAsync spawns a goroutine to consolidate reply for sessionKey.
// Returns immediately; errors are logged. ctx is used only to derive a
// background context with a fixed timeout — the goroutine is not cancelled
// if the parent context is cancelled (to survive request completion).
func (c *Consolidator) ConsolidateAsync(sessionKey, reply string) {
	if utf8.RuneCountInString(strings.TrimSpace(reply)) < minConsolidateLength {
		return
	}
	if c.obs != nil {
		c.obs.RecordConsolidationTriggered(context.Background())
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		n, err := c.consolidate(ctx, sessionKey, reply)
		if err != nil {
			slog.Warn("consolidator: failed", "session", sessionKey, "err", err)
			return
		}
		if n > 0 {
			slog.Debug("consolidator: indexed facts", "session", sessionKey, "count", n)
		}
	}()
}

// consolidate runs the LLM extraction and indexes facts. Returns the number
// of facts indexed. Exported for testing via a direct call.
func (c *Consolidator) consolidate(ctx context.Context, sessionKey, reply string) (int, error) {
	prompt := c.prompt + reply
	if !strings.Contains(c.prompt, "reply") && !strings.HasSuffix(c.prompt, "\n") {
		prompt = c.prompt + "\n\nAgent reply to consolidate:\n" + reply
	}
	response, err := c.runner.RunText(ctx, sessionKey, prompt, "")
	if err != nil {
		return 0, fmt.Errorf("consolidator: RunText: %w", err)
	}

	facts, err := parseFacts(response)
	if err != nil {
		return 0, fmt.Errorf("consolidator: parseFacts: %w", err)
	}
	if len(facts) == 0 {
		return 0, nil
	}

	// Record facts extracted (F-068)
	if c.obs != nil {
		c.obs.RecordFactsExtracted(ctx, int64(len(facts)))
	}

	indexed := 0
	skipped := 0
	for _, fact := range facts {
		fact = strings.TrimSpace(fact)
		if fact == "" {
			continue
		}
		// Deduplication: skip if a very similar fact is already in the store.
		// F-071: Search across both session and global namespaces.
		if existing, err := c.store.Search(fact, sessionKey, 1); err == nil && len(existing) > 0 {
			if existingContent, ok := existing[0]["content"].(string); ok {
				if similarity(fact, existingContent) > 0.8 {
					slog.Debug("consolidator: skipping duplicate fact", "fact", fact)
					skipped++
					continue
				}
			}
		}

		// F-071: Route to global if matches patterns, else session-scoped.
		namespace := "session:" + sessionKey
		for _, p := range c.patterns {
			if strings.Contains(strings.ToLower(fact), strings.ToLower(p)) {
				namespace = "global"
				break
			}
		}

		if indexErr := c.store.Index(namespace, fact); indexErr != nil {
			slog.Warn("consolidator: index failed", "fact", fact, "err", indexErr)
			skipped++
			continue
		}

		// F-030: Also index in vector store if available (semantic memory)
		if c.vecStore != nil && c.embedProv != nil {
			doc := chromem.Document{
				ID:      fmt.Sprintf("%s-%d", sessionKey, time.Now().UnixNano()),
				Content: fact,
				Metadata: map[string]string{
					"session_key": sessionKey,
					"namespace":   namespace, // F-071: Support namespacing in vectors
					"timestamp":   time.Now().UTC().Format(time.RFC3339),
					"source":      "consolidator",
				},
			}
			embedFunc := func(ctx context.Context, text string) ([]float32, error) {
				return c.embedProv.Embed(ctx, text)
			}
			if err := c.vecStore.AddDocument(ctx, "memory_facts", doc, embedFunc); err != nil {
				slog.Warn("consolidator: vector index failed", "fact", fact, "err", err)
			}
		}

		indexed++
	}

	// F-030: Save vector store after batch indexing
	if c.vecStore != nil && indexed > 0 {
		if err := c.vecStore.Save(); err != nil {
			slog.Warn("consolidator: failed to save vector db", "err", err)
		}
	}

	// Record metrics (F-068)
	if c.obs != nil {
		c.obs.RecordFactsIndexed(ctx, int64(indexed))
		if skipped > 0 {
			c.obs.RecordFactsSkipped(ctx, int64(skipped))
		}
	}

	// F-071: Perform per-namespace TTL cleanup.
	if c.ttl != "" {
		if deleted, err := c.store.CleanupNamespace("session:"+sessionKey, c.ttl); err != nil {
			slog.Warn("consolidator: session cleanup failed", "err", err)
		} else if deleted > 0 {
			slog.Debug("consolidator: session cleanup completed", "deleted", deleted)
		}
	}
	if c.globalTTL != "" {
		if deleted, err := c.store.CleanupNamespace("global", c.globalTTL); err != nil {
			slog.Warn("consolidator: global cleanup failed", "err", err)
		} else if deleted > 0 {
			slog.Debug("consolidator: global cleanup completed", "deleted", deleted)
		}
	}

	return indexed, nil
}

// parseFacts extracts a []string from the LLM's JSON response.
// Handles responses that wrap the array in markdown code fences.
func parseFacts(response string) ([]string, error) {
	// Strip markdown code fences if present.
	s := strings.TrimSpace(response)
	s = strings.TrimPrefix(s, "```json")
	s = strings.TrimPrefix(s, "```")
	s = strings.TrimSuffix(s, "```")
	s = strings.TrimSpace(s)

	// Find the JSON array.
	start := strings.Index(s, "[")
	end := strings.LastIndex(s, "]")
	if start == -1 || end == -1 || end < start {
		return nil, fmt.Errorf("parseFacts: no JSON array found in response")
	}
	s = s[start : end+1]

	var facts []string
	if err := json.Unmarshal([]byte(s), &facts); err != nil {
		return nil, fmt.Errorf("parseFacts: unmarshal: %w", err)
	}
	return facts, nil
}

// similarity returns a rough word-overlap ratio between two strings (0–1).
// Used for lightweight deduplication — not a semantic comparison.
func similarity(a, b string) float64 {
	wordsA := wordSet(a)
	wordsB := wordSet(b)
	if len(wordsA) == 0 || len(wordsB) == 0 {
		return 0
	}
	overlap := 0
	for w := range wordsA {
		if wordsB[w] {
			overlap++
		}
	}
	shorter := len(wordsA)
	if len(wordsB) < shorter {
		shorter = len(wordsB)
	}
	return float64(overlap) / float64(shorter)
}

func wordSet(s string) map[string]bool {
	words := strings.Fields(strings.ToLower(s))
	set := make(map[string]bool, len(words))
	for _, w := range words {
		set[w] = true
	}
	return set
}
