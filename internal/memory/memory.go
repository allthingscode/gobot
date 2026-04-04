// Package memory implements RAG, context-pruning, and journal helpers (F-030 port).
// Pure functions live here; file I/O lives in journal.go.
package memory

import (
	"encoding/json"
	"regexp"
	"strings"
	"time"
)

// ── Constants ─────────────────────────────────────────────────────────────────

// genericSkipPatterns is the set of short/trivial messages that should not
// trigger a RAG lookup (F-030).
var genericSkipPatterns = map[string]bool{
	"yes": true, "no": true, "ok": true, "okay": true,
	"hello": true, "hi": true, "thanks": true, "thank you": true,
	"confirmed": true, "ok.": true, "okay.": true, "confirmed.": true,
	"yes.": true, "no.": true, "thanks.": true, "hello.": true, "hi.": true,
}

// ragNoisePatterns are substrings that identify orchestration noise in RAG results.
var ragNoisePatterns = []string{
	"spawned subagent",
	"i have spawned",
	"specialist has been assigned id",
	"your turn is now over",
	"provide a single brief acknowledgement",
}

// timestampFormats tried in order when parsing message timestamps.
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
func PruneContext(messages []map[string]any, ttlHours int, keepLastAssistants int) []map[string]any {
	cutoff := time.Now().Add(-time.Duration(ttlHours) * time.Hour)

	keepSet := make(map[int]bool, len(messages))
	assistantCount := 0
	neededToolIDs := make(map[string]bool)

	// Pass 1: identify keepers (reverse order so newest assistant turns count first).
	for i := len(messages) - 1; i >= 0; i-- {
		m := messages[i]
		role, _ := m["role"].(string)

		isOld := false
		if ts, ok := m["timestamp"].(string); ok {
			if t := parseTimestamp(ts); !t.IsZero() {
				isOld = t.Before(cutoff)
			}
		}

		keep := false
		switch role {
		case "user":
			keep = true
		case "assistant":
			assistantCount++
			if !isOld || assistantCount <= keepLastAssistants {
				keep = true
				// Collect tool call IDs so their tool responses are kept too.
				if tcs, ok := m["tool_calls"].([]any); ok {
					for _, tc := range tcs {
						if tcm, ok := tc.(map[string]any); ok {
							if id, ok := tcm["id"].(string); ok && id != "" {
								neededToolIDs[id] = true
							}
						}
					}
				}
			}
		}
		if keep {
			keepSet[i] = true
		}
	}

	// Pass 2: build result in original order, adding tool responses as needed.
	result := make([]map[string]any, 0, len(messages))
	for i, m := range messages {
		if keepSet[i] {
			result = append(result, m)
			continue
		}
		role, _ := m["role"].(string)
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
	var lines []string
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
// Returns a map with "history_entry" and/or "memory_update" keys, or nil if
// the response cannot be parsed into a valid consolidation result.
func ParseConsolidationResponse(content any, hasToolCalls bool, toolArguments any, currentMemory string) map[string]any {
	var args map[string]any

	if hasToolCalls {
		switch v := toolArguments.(type) {
		case map[string]any:
			args = v
		case string:
			_ = json.Unmarshal([]byte(v), &args)
		}
	}

	// Regex recovery if tool call failed or content is raw text.
	if len(args) == 0 {
		contentStr := ""
		switch v := content.(type) {
		case string:
			contentStr = v
		default:
			if b, err := json.Marshal(v); err == nil {
				contentStr = string(b)
			}
		}
		if candidate, ok := extractJSON(contentStr); ok {
			args = map[string]any{
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
			}
		}
	}

	if len(args) == 0 {
		return nil
	}
	_, hasHistory := args["history_entry"]
	_, hasMemory := args["memory_update"]
	if !hasHistory && !hasMemory {
		return nil
	}
	return args
}

var reJSONObj = regexp.MustCompile(`(?s)(\{.*\})`)

func extractJSON(s string) (map[string]any, bool) {
	m := reJSONObj.FindString(s)
	if m == "" {
		return nil, false
	}
	var out map[string]any
	if err := json.Unmarshal([]byte(m), &out); err != nil {
		return nil, false
	}
	return out, true
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
func FormatRAGBlock(results []map[string]any) (string, int) {
	if len(results) == 0 {
		return "", 0
	}
	lines := make([]string, len(results))
	for i, r := range results {
		lines[i] = "- " + r["content"].(string)
	}
	warning := "[STRATEGIC MEMORY - MAY BE STALE OR OUTDATED. USE RESEARCH TOOLS TO VERIFY.]\n"
	block := "### RETRIEVED HISTORICAL CONTEXT:\n" + warning + "\n" + strings.Join(lines, "\n")
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
