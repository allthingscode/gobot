// Package memory implements RAG, context-pruning, and journal helpers (F-030 port).
// Pure functions live here; file I/O lives in journal.go.
package memory

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"regexp"
	"strings"
	"time"
)

// ── Constants ─────────────────────────────────────────────────────────────────

// genericSkipPatterns is the set of short/trivial messages that should not
// trigger a RAG lookup (F-030).
//
//nolint:gochecknoglobals // Immutable skip patterns for RAG noise filtering
var genericSkipPatterns = map[string]bool{
	"yes": true, "no": true, "ok": true, "okay": true,
	"hello": true, "hi": true, "thanks": true, "thank you": true,
	"confirmed": true, "ok.": true, "okay.": true, "confirmed.": true,
	"yes.": true, "no.": true, "thanks.": true, "hello.": true, "hi.": true,
}

// ragNoisePatterns are substrings that identify orchestration noise in RAG results.
//
//nolint:gochecknoglobals // Immutable noise patterns for RAG filtering
var ragNoisePatterns = []string{
	"spawned subagent",
	"i have spawned",
	"specialist has been assigned id",
	"your turn is now over",
	"provide a single brief acknowledgement",
}

// timestampFormats tried in order when parsing message timestamps.
//
//nolint:gochecknoglobals // Immutable timestamp formats for parsing
var timestampFormats = []string{
	time.RFC3339,
	"2006-01-02T15:04:05",
	"2006-01-02 15:04:05",
	"2006-01-02T15:04:05Z07:00",
}

// ── PruneContext ──────────────────────────────────────────────────────────────

// PruneContext prunes a slice of messages based on TTL and mandatory retention
// of recent assistant turns. Returns a new slice in the original order.
//
// Rules:
//   - User messages are always kept.
//   - The most recent keepLastAssistants assistant messages are always kept,
//     regardless of age.
//   - Older assistant messages are dropped if their timestamp predates the cutoff.
//   - Tool messages whose tool_call_id is referenced by a kept assistant turn
//     are kept to preserve the conversation structure.
func PruneContext(messages []map[string]any, ttlHours, keepLastAssistants int) []map[string]any {
	cutoff := time.Now().Add(-time.Duration(ttlHours) * time.Hour)

	keepSet := make(map[int]bool, len(messages))
	assistantCount := 0
	neededToolIDs := make(map[string]bool)

	// Pass 1: identify keepers (reverse order so newest assistant turns count first).
	for i := len(messages) - 1; i >= 0; i-- {
		m := messages[i]
		role := stringVal(m, "role")

		keep := false
		switch role {
		case "user":
			keep = true
		case "assistant":
			assistantCount++
			if shouldKeepAssistant(m, cutoff, assistantCount, keepLastAssistants) {
				keep = true
				collectToolIDs(m, neededToolIDs)
			}
		}
		if keep {
			keepSet[i] = true
		}
	}

	return buildPrunedResult(messages, keepSet, neededToolIDs)
}

func shouldKeepAssistant(m map[string]any, cutoff time.Time, count, minKeep int) bool {
	if count <= minKeep {
		return true
	}
	if ts, ok := m["timestamp"].(string); ok {
		if t := parseTimestamp(ts); !t.IsZero() {
			return !t.Before(cutoff)
		}
	}
	return true // keep if timestamp missing or unparseable
}

func collectToolIDs(m map[string]any, needed map[string]bool) {
	tcs, ok := m["tool_calls"].([]any)
	if !ok {
		return
	}
	for _, tc := range tcs {
		tcm, ok := tc.(map[string]any)
		if !ok {
			continue
		}
		if id, ok := tcm["id"].(string); ok && id != "" {
			needed[id] = true
		}
	}
}

func buildPrunedResult(messages []map[string]any, keepSet map[int]bool, neededToolIDs map[string]bool) []map[string]any {
	result := make([]map[string]any, 0, len(messages))
	for i, m := range messages {
		if keepSet[i] {
			result = append(result, m)
			continue
		}
		role := stringVal(m, "role")
		if role == "tool" {
			if id, ok := m["tool_call_id"].(string); ok && neededToolIDs[id] {
				result = append(result, m)
			}
		}
	}
	return result
}


func parseTimestamp(s string) time.Time {
	for _, f := range timestampFormats {
		if t, err := time.Parse(f, s); err == nil {
			return t
		}
	}
	return time.Time{}
}

// ── FormatConsolidationMessages ───────────────────────────────────────────────

// FormatConsolidationMessages formats a slice of messages into a human-readable
// string for use in the consolidator prompt.
func FormatConsolidationMessages(messages []map[string]any) string {
	lines := make([]string, 0, len(messages))
	for _, m := range messages {
		content, ok := m["content"].(string)
		if !ok || content == "" {
			continue
		}
		ts, _ := m["timestamp"].(string)
		if len(ts) > 16 {
			ts = ts[:16]
		}
		if ts == "" {
			ts = "?"
		}
		role := strings.ToUpper(stringVal(m, "role"))
		lines = append(lines, "["+ts+"] "+role+": "+content)
	}
	return strings.Join(lines, "\n")
}

// ── ParseConsolidationResponse ────────────────────────────────────────────────

// ParseConsolidationResponse parses the LLM response from a consolidation turn
// (from tool calls or raw text) and applies regex recovery if needed.
//
// Returns a map with "history_entry" and/or "memory_update" keys, or an error if
// the response cannot be parsed into a valid consolidation result.
func ParseConsolidationResponse(content any, hasToolCalls bool, toolArguments any, currentMemory string) (map[string]any, error) {
	args, err := tryParseFromTool(hasToolCalls, toolArguments)
	if err == nil && len(args) > 0 {
		return validateConsolidationKeys(args, content)
	}

	// Regex recovery if tool call failed or content is raw text.
	args, err = tryParseFromText(content, currentMemory)
	if err != nil {
		return nil, err
	}

	return validateConsolidationKeys(args, content)
}

func tryParseFromTool(hasToolCalls bool, toolArguments any) (map[string]any, error) {
	if !hasToolCalls {
		return nil, nil
	}
	switch v := toolArguments.(type) {
	case map[string]any:
		return v, nil
	case string:
		var args map[string]any
		if err := json.Unmarshal([]byte(v), &args); err != nil {
			slog.Error("consolidation: failed to unmarshal tool arguments",
				"error", err,
				"raw_content", truncateString(v, 500))
			return nil, err
		}
		return args, nil
	}
	return nil, nil
}

func tryParseFromText(content any, currentMemory string) (map[string]any, error) {
	contentStr := stringify(content)
	candidate, err := extractJSON(contentStr)
	if err != nil {
		slog.Error("consolidation: failed to parse LLM response as JSON",
			"error", err,
			"raw_response", truncateString(contentStr, 500))
		return nil, fmt.Errorf("consolidation: failed to parse LLM response as JSON: %w", err)
	}

	return map[string]any{
		"history_entry": firstNonEmpty(
			stringVal(candidate, "history_entry"),
			stringVal(candidate, "summary"),
			"No summary available.",
		),
		"memory_update": firstNonEmpty(
			stringVal(candidate, "memory_update"),
			stringVal(candidate, "facts"),
			currentMemory,
		),
	}, nil
}

func stringify(content any) string {
	switch v := content.(type) {
	case string:
		return v
	default:
		if b, err := json.Marshal(v); err == nil {
			return string(b)
		}
	}
	return ""
}

func validateConsolidationKeys(args map[string]any, content any) (map[string]any, error) {
	if len(args) == 0 {
		return nil, fmt.Errorf("consolidation: no valid consolidation data found")
	}
	_, hasHistory := args["history_entry"]
	_, hasMemory := args["memory_update"]
	if !hasHistory && !hasMemory {
		slog.Error("consolidation: response missing required keys",
			"raw_content", truncateString(fmt.Sprintf("%v", content), 500))
		return nil, fmt.Errorf("consolidation: response missing required keys (history_entry/memory_update)")
	}
	return args, nil
}

var reJSONObj = regexp.MustCompile(`(?s)(\{.*\})`)

func extractJSON(s string) (map[string]any, error) {
	m := reJSONObj.FindString(s)
	if m == "" {
		return nil, fmt.Errorf("extractJSON: no JSON object found in string")
	}
	var out map[string]any
	if err := json.Unmarshal([]byte(m), &out); err != nil {
		return nil, fmt.Errorf("extractJSON: failed to unmarshal JSON: %w", err)
	}
	return out, nil
}

// ── RAG helpers ───────────────────────────────────────────────────────────────

// FilterRAGResults filters out noise and low-relevance matches from RAG results.
// threshold is the minimum score (0–1) for a result to be included.
func FilterRAGResults(results []map[string]any, threshold float64) []map[string]any {
	out := make([]map[string]any, 0, len(results))
	for _, r := range results {
		content, _ := r["content"].(string)
		if content == "" || strings.Contains(content, "No summary available") {
			continue
		}
		score := 1.0
		if s, ok := r["score"].(float64); ok {
			score = s
		}
		if score < threshold {
			continue
		}
		lower := strings.ToLower(content)
		noisy := false
		for _, p := range ragNoisePatterns {
			if strings.Contains(lower, p) {
				noisy = true
				break
			}
		}
		if noisy {
			continue
		}
		out = append(out, r)
	}
	return out
}

// ShouldSkipRAG returns true if the content is too short or generic to warrant
// a RAG lookup.
func ShouldSkipRAG(content string) bool {
	clean := strings.ToLower(strings.TrimSpace(content))
	return len(content) <= 10 || genericSkipPatterns[clean] || content == "[empty message]"
}

// IsTrivialMessageForConsolidation returns true if the message is too trivial
// to warrant fact extraction during memory consolidation (F-068).
// Unlike ShouldSkipRAG, this only filters truly trivial acknowledgements,
// not all short messages.
func IsTrivialMessageForConsolidation(content string) bool {
	clean := strings.ToLower(strings.TrimSpace(content))
	return genericSkipPatterns[clean] || content == "[empty message]"
}

// FormatRAGBlock formats valid RAG results into a prompt block.
// Returns (block, count); block is empty string and count is 0 when no results.
func FormatRAGBlock(results []map[string]any) (block string, count int) {
	if len(results) == 0 {
		return "", 0
	}
	lines := make([]string, len(results))
	for i, r := range results {
		lines[i] = "- " + r["content"].(string)
	}
	warning := "[STRATEGIC MEMORY - MAY BE STALE OR OUTDATED. USE RESEARCH TOOLS TO VERIFY.]\n"
	block = "### RETRIEVED HISTORICAL CONTEXT:\n" + warning + "\n" + strings.Join(lines, "\n")
	return block, len(results)
}

// ── Helpers ───────────────────────────────────────────────────────────────────

func stringVal(m map[string]any, key string) string {
	s, _ := m[key].(string)
	return s
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}

func truncateString(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen] + "..."
}
