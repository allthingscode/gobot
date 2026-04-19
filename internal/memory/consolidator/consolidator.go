package consolidator

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"strconv"
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

Return ONLY a JSON array of objects with "fact" (string) and "importance" (integer 1-5) keys.
1 = trivial/conversational, 3 = useful context, 5 = critical decision/deadline/preference.
Return [] if no notable facts. Do not include filler.

Example output:
[{"fact": "Project Alpha deadline is May 1 2026", "importance": 5},
 {"fact": "User prefers async updates on Fridays", "importance": 4}]

Agent reply to consolidate:
`

// ScoredFact is a fact extracted by the consolidation LLM with an importance score.
type ScoredFact struct {
	Fact       string
	Importance int // 1–5; 0 means unscored (treated as default 3)
}

// TextRunner is the interface used by Consolidator to make a single LLM call.
// agentRunner in cmd/gobot/runner.go implements this via RunText.
type TextRunner interface {
	RunText(ctx context.Context, sessionKey, prompt string, modelOverride string) (string, error)
}

// Consolidator extracts facts from agent replies and indexes them into the
// long-term memory store. All operations are best-effort — errors are logged
// and never propagated to the caller.
type Consolidator struct {
	runner                 TextRunner
	store                  *memory.MemoryStore
	vecStore               *vector.Store            // F-030: Semantic memory
	embedProv              vector.EmbeddingProvider // F-030: Semantic memory
	semanticDedupThreshold float64                  // F-112: Semantic deduplication threshold (0 to disable)
	prompt                 string
	ttl                    string                  // e.g., "2160h" for 90 days; empty means no cleanup
	globalTTL              string                  // F-071: TTL for global namespace
	patterns               []string                // F-071: Patterns for global routing
	obs                    *observability.Provider // optional observability provider
}

// New creates a Consolidator. Both runner and store must be non-nil.
// vecStore and embedProv may be nil (semantic memory disabled).
func New(runner TextRunner, store *memory.MemoryStore, vecStore *vector.Store, embedProv vector.EmbeddingProvider) *Consolidator {
	return &Consolidator{
		runner:                 runner,
		store:                  store,
		vecStore:               vecStore,
		embedProv:              embedProv,
		semanticDedupThreshold: 0.92, // default threshold
		prompt:                 consolidationPrompt,
		ttl:                    "",
		globalTTL:              "",
		patterns:               nil,
		obs:                    nil,
	}
}

// SetSemanticDedupThreshold sets the threshold for semantic deduplication (0-1).
// If set to 0 or less, semantic deduplication is disabled.
func (c *Consolidator) SetSemanticDedupThreshold(t float64) {
	c.semanticDedupThreshold = t
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
	facts, err := c.extractFacts(ctx, sessionKey, reply)
	if err != nil {
		return 0, err
	}
	if len(facts) == 0 {
		return 0, nil
	}

	if c.obs != nil {
		c.obs.RecordFactsExtracted(ctx, int64(len(facts)))
	}

	indexed, skipped := c.indexFacts(ctx, sessionKey, facts)

	if c.vecStore != nil && indexed > 0 {
		if err := c.vecStore.Save(); err != nil {
			slog.Warn("consolidator: failed to save vector db", "err", err)
		}
	}

	if c.obs != nil {
		c.obs.RecordFactsIndexed(ctx, int64(indexed))
		if skipped > 0 {
			c.obs.RecordFactsSkipped(ctx, int64(skipped))
		}
	}

	c.cleanupNamespaces(sessionKey)
	return indexed, nil
}

func (c *Consolidator) extractFacts(ctx context.Context, sessionKey, reply string) ([]ScoredFact, error) {
	prompt := c.prompt + reply
	if !strings.Contains(c.prompt, "reply") && !strings.HasSuffix(c.prompt, "\n") {
		prompt = c.prompt + "\n\nAgent reply to consolidate:\n" + reply
	}
	response, err := c.runner.RunText(ctx, sessionKey, prompt, "")
	if err != nil {
		return nil, fmt.Errorf("consolidator: RunText: %w", err)
	}

	return parseScoredFacts(response)
}

func (c *Consolidator) indexFacts(ctx context.Context, sessionKey string, facts []ScoredFact) (indexed, skipped int) {
	indexed = 0
	skipped = 0
	for _, sf := range facts {
		fact := strings.TrimSpace(sf.Fact)
		if fact == "" {
			continue
		}

		if c.isDuplicate(ctx, sessionKey, fact) {
			skipped++
			continue
		}

		namespace := c.resolveNamespace(fact, sessionKey)
		if err := c.store.IndexWithImportance(namespace, fact, sf.Importance); err != nil {
			slog.Warn("consolidator: index failed", "fact", fact, "err", err)
			skipped++
			continue
		}

		c.indexVectorFact(ctx, sessionKey, fact, namespace, sf.Importance)
		indexed++
	}
	return indexed, skipped
}

func (c *Consolidator) isDuplicate(ctx context.Context, sessionKey, fact string) bool {
	// F-112: Use semantic deduplication if vector store is available.
	if c.vecStore != nil && c.embedProv != nil && c.semanticDedupThreshold > 0 {
		return c.isSemanticDuplicate(ctx, sessionKey, fact)
	}

	// Fallback to lexical word-overlap (existing logic).
	return c.isLexicalDuplicate(sessionKey, fact)
}

func (c *Consolidator) isSemanticDuplicate(ctx context.Context, sessionKey, fact string) bool {
	embedFunc := func(ctx context.Context, text string) ([]float32, error) {
		return c.embedProv.Embed(ctx, text)
	}
	// Search for nearest existing fact. Fetch top 5 to check for session/global matches.
	results, err := c.vecStore.Search(ctx, "memory_facts", fact, 5, nil, embedFunc)
	if err != nil {
		return false
	}

	for _, res := range results {
		// Only deduplicate against facts in the same session or global namespace.
		isGlobal := res.Metadata["namespace"] == "global"
		isSameSession := res.Metadata["session_key"] == sessionKey

		if (isGlobal || isSameSession) && float64(res.Similarity) >= c.semanticDedupThreshold {
			slog.Debug("consolidator: skipping semantic duplicate fact",
				"fact", fact,
				"existing", res.Content,
				"similarity", res.Similarity,
				"namespace", res.Metadata["namespace"])
			return true
		}
	}

	// If semantic check is enabled but no match found, we skip lexical check to avoid
	// inconsistent behavior (semantic is the upgrade).
	return false
}

func (c *Consolidator) isLexicalDuplicate(sessionKey, fact string) bool {
	existing, err := c.store.Search(fact, sessionKey, 1)
	if err != nil || len(existing) == 0 {
		return false
	}

	if existingContent, ok := existing[0]["content"].(string); ok {
		if similarity(fact, existingContent) > 0.8 {
			slog.Debug("consolidator: skipping lexical duplicate fact", "fact", fact)
			return true
		}
	}
	return false
}

func (c *Consolidator) resolveNamespace(fact, sessionKey string) string {
	for _, p := range c.patterns {
		if strings.Contains(strings.ToLower(fact), strings.ToLower(p)) {
			return "global"
		}
	}
	return "session:" + sessionKey
}

func (c *Consolidator) indexVectorFact(ctx context.Context, sessionKey, fact, namespace string, importance int) {
	if c.vecStore == nil || c.embedProv == nil {
		return
	}

	doc := chromem.Document{
		ID:      fmt.Sprintf("%s-%d", sessionKey, time.Now().UnixNano()),
		Content: fact,
		Metadata: map[string]string{
			"session_key": sessionKey,
			"namespace":   namespace,
			"timestamp":   time.Now().UTC().Format(time.RFC3339),
			"source":      "consolidator",
			"importance":  strconv.Itoa(importance),
		},
	}
	embedFunc := func(ctx context.Context, text string) ([]float32, error) {
		return c.embedProv.Embed(ctx, text)
	}
	if err := c.vecStore.AddDocument(ctx, "memory_facts", doc, embedFunc); err != nil {
		slog.Warn("consolidator: vector index failed", "fact", fact, "err", err)
	}
}

func (c *Consolidator) cleanupNamespaces(sessionKey string) {
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
}

// scoredFactJSON is the wire format returned by the consolidation LLM.
type scoredFactJSON struct {
	Fact       string `json:"fact"`
	Importance int    `json:"importance"`
}

// parseScoredFacts extracts []ScoredFact from the LLM's JSON response.
// Handles markdown code fences and two response formats:
//   - scored: [{"fact":"...", "importance":N}, ...]
//   - legacy plain-string: ["...", "..."] — wrapped with importance=3
func parseScoredFacts(response string) ([]ScoredFact, error) {
	s := strings.TrimSpace(response)
	s = strings.TrimPrefix(s, "```json")
	s = strings.TrimPrefix(s, "```")
	s = strings.TrimSuffix(s, "```")
	s = strings.TrimSpace(s)

	start := strings.Index(s, "[")
	end := strings.LastIndex(s, "]")
	if start == -1 || end == -1 || end < start {
		return nil, fmt.Errorf("parseScoredFacts: no JSON array found in response")
	}
	s = s[start : end+1]

	// Try scored object format first.
	var scored []scoredFactJSON
	if err := json.Unmarshal([]byte(s), &scored); err == nil {
		facts := make([]ScoredFact, 0, len(scored))
		for _, sf := range scored {
			imp := sf.Importance
			if imp < 1 || imp > 5 {
				imp = 3
			}
			facts = append(facts, ScoredFact{Fact: sf.Fact, Importance: imp})
		}
		return facts, nil
	}

	// Fall back to plain-string array (legacy LLM responses).
	var plain []string
	if err := json.Unmarshal([]byte(s), &plain); err != nil {
		return nil, fmt.Errorf("parseScoredFacts: unmarshal: %w", err)
	}
	facts := make([]ScoredFact, 0, len(plain))
	for _, f := range plain {
		facts = append(facts, ScoredFact{Fact: f, Importance: 3})
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
