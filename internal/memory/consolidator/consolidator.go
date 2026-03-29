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
	RunText(ctx context.Context, prompt string) (string, error)
}

// Consolidator extracts facts from agent replies and indexes them into the
// long-term memory store. All operations are best-effort — errors are logged
// and never propagated to the caller.
type Consolidator struct {
	runner TextRunner
	store  *memory.MemoryStore
}

// New creates a Consolidator. Both runner and store must be non-nil.
func New(runner TextRunner, store *memory.MemoryStore) *Consolidator {
	return &Consolidator{runner: runner, store: store}
}

// ConsolidateAsync spawns a goroutine to consolidate reply for sessionKey.
// Returns immediately; errors are logged. ctx is used only to derive a
// background context with a fixed timeout — the goroutine is not cancelled
// if the parent context is cancelled (to survive request completion).
func (c *Consolidator) ConsolidateAsync(sessionKey, reply string) {
	if utf8.RuneCountInString(strings.TrimSpace(reply)) < minConsolidateLength {
		return
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
	prompt := consolidationPrompt + reply
	response, err := c.runner.RunText(ctx, prompt)
	if err != nil {
		return 0, fmt.Errorf("consolidator: RunText: %w", err)
	}

	facts, err := parseFacts(response)
	if err != nil || len(facts) == 0 {
		return 0, nil
	}

	indexed := 0
	for _, fact := range facts {
		fact = strings.TrimSpace(fact)
		if fact == "" {
			continue
		}
		// Deduplication: skip if a very similar fact is already in the store.
		if existing, _ := c.store.Search(fact, 1); len(existing) > 0 {
			existingContent, _ := existing[0]["content"].(string)
			if similarity(fact, existingContent) > 0.8 {
				slog.Debug("consolidator: skipping duplicate fact", "fact", fact)
				continue
			}
		}
		if indexErr := c.store.Index(sessionKey, fact); indexErr != nil {
			slog.Warn("consolidator: index failed", "fact", fact, "err", indexErr)
			continue
		}
		indexed++
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
