package memory_test

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/memory"
)

// ── helpers ───────────────────────────────────────────────────────────────────

func msg(role, content string) map[string]any {
	return map[string]any{"role": role, "content": content}
}

func msgWithTS(role, content, ts string) map[string]any {
	return map[string]any{"role": role, "content": content, "timestamp": ts}
}

// ── PruneContext ──────────────────────────────────────────────────────────────

func TestPruneContext_UserMessagesAlwaysKept(t *testing.T) {
	old := time.Now().Add(-48 * time.Hour).Format(time.RFC3339)
	msgs := []map[string]any{
		msgWithTS("user", "hello", old),
		msgWithTS("assistant", "hi", old),
	}
	result := memory.PruneContext(msgs, 24, 0)
	// user kept, old assistant with 0 keepLast dropped
	if len(result) != 1 {
		t.Fatalf("expected 1 message, got %d", len(result))
	}
	if result[0]["role"] != "user" {
		t.Error("expected the kept message to be the user message")
	}
}

func TestPruneContext_KeepLastAssistants(t *testing.T) {
	old := time.Now().Add(-48 * time.Hour).Format(time.RFC3339)
	msgs := []map[string]any{
		msgWithTS("assistant", "old1", old),
		msgWithTS("assistant", "old2", old),
		msgWithTS("user", "q", old),
	}
	result := memory.PruneContext(msgs, 1, 2)
	// keepLastAssistants=2 — both old assistants should be kept
	roles := make([]string, len(result))
	for i, m := range result {
		roles[i] = m["role"].(string)
	}
	if len(result) != 3 {
		t.Errorf("expected 3 messages, got %d (%v)", len(result), roles)
	}
}

func TestPruneContext_ToolResponseRetainedWithAssistant(t *testing.T) {
	recent := time.Now().Format(time.RFC3339)
	msgs := []map[string]any{
		{
			"role":      "assistant",
			"content":   "calling tool",
			"timestamp": recent,
			"tool_calls": []any{
				map[string]any{"id": "call-123"},
			},
		},
		{
			"role":         "tool",
			"content":      "tool result",
			"tool_call_id": "call-123",
		},
	}
	result := memory.PruneContext(msgs, 1, 1)
	if len(result) != 2 {
		t.Fatalf("expected assistant + tool message, got %d", len(result))
	}
}

func TestPruneContext_ToolResponseDroppedWithAssistant(t *testing.T) {
	old := time.Now().Add(-48 * time.Hour).Format(time.RFC3339)
	msgs := []map[string]any{
		{
			"role":      "assistant",
			"content":   "old call",
			"timestamp": old,
			"tool_calls": []any{
				map[string]any{"id": "call-old"},
			},
		},
		{
			"role":         "tool",
			"content":      "old result",
			"tool_call_id": "call-old",
		},
	}
	result := memory.PruneContext(msgs, 1, 0)
	// Old assistant dropped (keepLast=0), so tool response also dropped.
	if len(result) != 0 {
		t.Errorf("expected 0 messages, got %d", len(result))
	}
}

func TestPruneContext_OrderPreserved(t *testing.T) {
	recent := time.Now().Format(time.RFC3339)
	msgs := []map[string]any{
		msgWithTS("user", "first", recent),
		msgWithTS("assistant", "second", recent),
		msgWithTS("user", "third", recent),
	}
	result := memory.PruneContext(msgs, 24, 5)
	for i, m := range result {
		if m["content"] != msgs[i]["content"] {
			t.Errorf("order mismatch at %d: got %v want %v", i, m["content"], msgs[i]["content"])
		}
	}
}

func TestPruneContext_EmptyInput(t *testing.T) {
	result := memory.PruneContext(nil, 24, 5)
	if len(result) != 0 {
		t.Errorf("expected empty result for nil input, got %d", len(result))
	}
}

func TestPruneContext_NoTimestamp(t *testing.T) {
	// Messages without a timestamp are treated as not-old (zero time is not before cutoff).
	msgs := []map[string]any{
		msg("assistant", "no ts"),
	}
	result := memory.PruneContext(msgs, 1, 0)
	// No timestamp → isOld=false → kept even with keepLast=0.
	if len(result) != 1 {
		t.Errorf("expected message without timestamp to be kept, got %d", len(result))
	}
}

func TestPruneContext_SpaceFormatTimestamp(t *testing.T) {
	// Exercises the "2006-01-02 15:04:05" timestamp format parser branch.
	old := time.Now().Add(-48 * time.Hour).Format("2006-01-02 15:04:05")
	msgs := []map[string]any{
		msgWithTS("assistant", "space-format old", old),
		msgWithTS("user", "keep me", old),
	}
	result := memory.PruneContext(msgs, 1, 0)
	// Old assistant dropped; user always kept.
	if len(result) != 1 || result[0]["role"] != "user" {
		t.Errorf("expected only user message, got %d messages", len(result))
	}
}

func TestPruneContext_UnparseableTimestamp(t *testing.T) {
	// Exercises the final return of parseTimestamp (all formats fail → zero time).
	msgs := []map[string]any{
		msgWithTS("assistant", "bad ts", "not-a-date"),
	}
	result := memory.PruneContext(msgs, 1, 0)
	// Unparseable timestamp → isOld=false → kept even with keepLast=0.
	if len(result) != 1 {
		t.Errorf("expected message with unparseable timestamp to be kept, got %d", len(result))
	}
}

func TestPruneContext_PlainDateTimeTimestamp(t *testing.T) {
	// Exercises the "2006-01-02T15:04:05" (no timezone) format parser branch.
	old := time.Now().Add(-48 * time.Hour).Format("2006-01-02T15:04:05")
	msgs := []map[string]any{
		msgWithTS("assistant", "no-tz old", old),
		msgWithTS("user", "keep me", old),
	}
	result := memory.PruneContext(msgs, 1, 0)
	if len(result) != 1 || result[0]["role"] != "user" {
		t.Errorf("expected only user message, got %d messages", len(result))
	}
}

// ── FormatConsolidationMessages ───────────────────────────────────────────────

func TestFormatConsolidationMessages_Basic(t *testing.T) {
	msgs := []map[string]any{
		{"role": "user", "content": "hello", "timestamp": "2026-03-27T10:00:00"},
		{"role": "assistant", "content": "world", "timestamp": "2026-03-27T10:01:00"},
	}
	got := memory.FormatConsolidationMessages(msgs)
	if !strings.Contains(got, "USER: hello") {
		t.Errorf("expected USER line, got:\n%s", got)
	}
	if !strings.Contains(got, "ASSISTANT: world") {
		t.Errorf("expected ASSISTANT line, got:\n%s", got)
	}
}

func TestFormatConsolidationMessages_SkipsEmptyContent(t *testing.T) {
	msgs := []map[string]any{
		{"role": "user", "content": ""},
		{"role": "assistant", "content": "response"},
	}
	got := memory.FormatConsolidationMessages(msgs)
	lines := strings.Split(strings.TrimSpace(got), "\n")
	if len(lines) != 1 {
		t.Errorf("expected 1 line (empty content skipped), got %d: %q", len(lines), got)
	}
}

func TestFormatConsolidationMessages_TimestampTruncated(t *testing.T) {
	msgs := []map[string]any{
		{"role": "user", "content": "hi", "timestamp": "2026-03-27T10:00:00.000Z"},
	}
	got := memory.FormatConsolidationMessages(msgs)
	// Should be truncated to 16 chars: "2026-03-27T10:00"
	if !strings.Contains(got, "[2026-03-27T10:00]") {
		t.Errorf("expected truncated timestamp, got: %s", got)
	}
}

func TestFormatConsolidationMessages_MissingTimestamp(t *testing.T) {
	msgs := []map[string]any{
		{"role": "user", "content": "hi"},
	}
	got := memory.FormatConsolidationMessages(msgs)
	if !strings.Contains(got, "[?]") {
		t.Errorf("expected [?] for missing timestamp, got: %s", got)
	}
}

// ── ParseConsolidationResponse ────────────────────────────────────────────────

func TestParseConsolidationResponse_ToolCallMap(t *testing.T) {
	args := map[string]any{
		"history_entry": "summary here",
		"memory_update": "new facts",
	}
	result, err := memory.ParseConsolidationResponse(nil, true, args, "old")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result == nil {
		t.Fatal("expected non-nil result")
	}
	if result["history_entry"] != "summary here" {
		t.Errorf("got %v", result["history_entry"])
	}
}

func TestParseConsolidationResponse_ToolCallJSONString(t *testing.T) {
	jsonStr := `{"history_entry":"from json","memory_update":"facts"}`
	result, err := memory.ParseConsolidationResponse(nil, true, jsonStr, "old")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result == nil {
		t.Fatal("expected non-nil result")
	}
	if result["history_entry"] != "from json" {
		t.Errorf("got %v", result["history_entry"])
	}
}

func TestParseConsolidationResponse_RegexRecovery(t *testing.T) {
	content := `Some preamble {"history_entry": "recovered", "memory_update": "data"} trailing`
	result, err := memory.ParseConsolidationResponse(content, false, nil, "old memory")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result == nil {
		t.Fatal("expected regex recovery to succeed")
	}
	if result["history_entry"] != "recovered" {
		t.Errorf("got %v", result["history_entry"])
	}
}

func TestParseConsolidationResponse_SummaryFallback(t *testing.T) {
	content := `{"summary": "alt key", "facts": "alt memory"}`
	result, err := memory.ParseConsolidationResponse(content, false, nil, "default mem")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result == nil {
		t.Fatal("expected non-nil result")
	}
	if result["history_entry"] != "alt key" {
		t.Errorf("expected 'alt key' via summary fallback, got %v", result["history_entry"])
	}
}

func TestParseConsolidationResponse_NilOnNoKeys(t *testing.T) {
	result, err := memory.ParseConsolidationResponse("no json here", false, nil, "old")
	if err == nil {
		t.Errorf("expected error for unparseable input, got result=%v", result)
	}
}

func TestParseConsolidationResponse_NonStringContent(t *testing.T) {
	// Non-string content (e.g. a number) — exercises the default json.Marshal branch.
	result, err := memory.ParseConsolidationResponse(42, false, nil, "old")
	if err == nil {
		t.Errorf("expected error for non-string numeric content, got result=%v", result)
	}
}

func TestParseConsolidationResponse_InvalidJSONInContent(t *testing.T) {
	// Regex finds braces but content is not valid JSON — exercises extractJSON failure.
	result, err := memory.ParseConsolidationResponse("{not valid json}", false, nil, "old")
	if err == nil {
		t.Errorf("expected error for invalid JSON content, got result=%v", result)
	}
}

func TestParseConsolidationResponse_AllMemoryKeysMissing(t *testing.T) {
	// Neither memory_update nor facts present, and currentMemory is "".
	// Exercises firstNonEmpty reaching its final return "".
	content := `{"history_entry": "got this", "unrelated": "data"}`
	result, err := memory.ParseConsolidationResponse(content, false, nil, "")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result == nil {
		t.Fatal("expected non-nil result")
	}
	// memory_update falls back to "" (all three args empty)
	if v, ok := result["memory_update"]; !ok || v != "" {
		t.Errorf("expected empty string for memory_update, got %v", v)
	}
}

func TestParseConsolidationResponse_NoSummaryFallback(t *testing.T) {
	// Neither history_entry nor summary present — firstNonEmpty falls through to default.
	content := `{"memory_update": "some facts"}`
	result, err := memory.ParseConsolidationResponse(content, false, nil, "old memory")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result == nil {
		t.Fatal("expected non-nil result")
	}
	// history_entry should fall back to "No summary available."
	if result["history_entry"] != "No summary available." {
		t.Errorf("got %v, want 'No summary available.'", result["history_entry"])
	}
}

func TestParseConsolidationResponse_NilOnEmptyArgsNoKeys(t *testing.T) {
	args := map[string]any{"irrelevant": "value"}
	result, err := memory.ParseConsolidationResponse(nil, true, args, "old")
	if err == nil {
		t.Errorf("expected error when args have no history/memory keys, got result=%v", result)
	}
}

// TestParseConsolidationResponse_ErrorHandling tests all three parse outcomes
// as required by B-040 implementation steps.
func TestParseConsolidationResponse_ErrorHandling(t *testing.T) {
	tests := []struct {
		name          string
		content       any
		hasToolCalls  bool
		toolArguments any
		currentMemory string
		wantError     bool
		checkResult   func(t *testing.T, result map[string]any)
	}{
		{
			name:          "valid JSON",
			content:       `{"history_entry": "valid", "memory_update": "facts"}`,
			hasToolCalls:  false,
			toolArguments: nil,
			currentMemory: "old",
			wantError:     false,
			checkResult: func(t *testing.T, result map[string]any) {
				if result["history_entry"] != "valid" {
					t.Errorf("expected history_entry='valid', got %v", result["history_entry"])
				}
			},
		},
		{
			name:          "invalid JSON with regex match",
			content:       `Some text {"history_entry": "recovered", "memory_update": "data"} more text`,
			hasToolCalls:  false,
			toolArguments: nil,
			currentMemory: "old",
			wantError:     false,
			checkResult: func(t *testing.T, result map[string]any) {
				if result["history_entry"] != "recovered" {
					t.Errorf("expected history_entry='recovered', got %v", result["history_entry"])
				}
			},
		},
		{
			name:          "invalid JSON with no regex match - expect error",
			content:       "no json here at all",
			hasToolCalls:  false,
			toolArguments: nil,
			currentMemory: "old",
			wantError:     true,
			checkResult: func(t *testing.T, result map[string]any) {
				if result != nil {
					t.Errorf("expected nil result on error, got %v", result)
				}
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, err := memory.ParseConsolidationResponse(tt.content, tt.hasToolCalls, tt.toolArguments, tt.currentMemory)
			if tt.wantError && err == nil {
				t.Errorf("expected error but got none")
			}
			if !tt.wantError && err != nil {
				t.Errorf("unexpected error: %v", err)
			}
			if tt.checkResult != nil {
				tt.checkResult(t, result)
			}
		})
	}
}

// ── FilterRAGResults ──────────────────────────────────────────────────────────

func TestFilterRAGResults_FiltersLowScore(t *testing.T) {
	results := []map[string]any{
		{"content": "good content", "score": 0.9},
		{"content": "bad content", "score": 0.5},
	}
	filtered := memory.FilterRAGResults(results, 0.7)
	if len(filtered) != 1 || filtered[0]["content"] != "good content" {
		t.Errorf("expected only high-score result, got %v", filtered)
	}
}

func TestFilterRAGResults_FiltersNoSummary(t *testing.T) {
	results := []map[string]any{
		{"content": "No summary available", "score": 1.0},
		{"content": "real content", "score": 1.0},
	}
	filtered := memory.FilterRAGResults(results, 0.7)
	if len(filtered) != 1 || filtered[0]["content"] != "real content" {
		t.Errorf("expected noise to be filtered, got %v", filtered)
	}
}

func TestFilterRAGResults_FiltersNoisePatterns(t *testing.T) {
	results := []map[string]any{
		{"content": "spawned subagent for task X", "score": 1.0},
		{"content": "Meeting summary: budget approved", "score": 1.0},
	}
	filtered := memory.FilterRAGResults(results, 0.7)
	if len(filtered) != 1 {
		t.Errorf("expected noise pattern filtered, got %d results", len(filtered))
	}
}

func TestFilterRAGResults_FiltersEmptyContent(t *testing.T) {
	results := []map[string]any{
		{"content": "", "score": 1.0},
		{"content": "valid", "score": 1.0},
	}
	filtered := memory.FilterRAGResults(results, 0.0)
	if len(filtered) != 1 {
		t.Errorf("expected empty content filtered, got %d", len(filtered))
	}
}

func TestFilterRAGResults_DefaultScoreIsOne(t *testing.T) {
	// Result with no "score" key should default to 1.0 and pass a 0.7 threshold.
	results := []map[string]any{
		{"content": "no score key"},
	}
	filtered := memory.FilterRAGResults(results, 0.7)
	if len(filtered) != 1 {
		t.Error("expected result with no score key to default to 1.0 and pass")
	}
}

// ── ShouldSkipRAG ─────────────────────────────────────────────────────────────

func TestShouldSkipRAG(t *testing.T) {
	tests := []struct {
		input string
		want  bool
	}{
		{"yes", true},
		{"ok.", true},
		{"hello", true},
		{"[empty message]", true},
		{"hi", true},    // len ≤ 10
		{"short", true}, // len ≤ 10
		{"What is the status of project Alpha?", false},
		{"Summarize today's meetings", false},
	}
	for _, tt := range tests {
		t.Run(fmt.Sprintf("%q", tt.input), func(t *testing.T) {
			got := memory.ShouldSkipRAG(tt.input)
			if got != tt.want {
				t.Errorf("ShouldSkipRAG(%q) = %v, want %v", tt.input, got, tt.want)
			}
		})
	}
}

// ── FormatRAGBlock ────────────────────────────────────────────────────────────

func TestFormatRAGBlock_Basic(t *testing.T) {
	results := []map[string]any{
		{"content": "fact one"},
		{"content": "fact two"},
	}
	block, count := memory.FormatRAGBlock(results)
	if count != 2 {
		t.Errorf("expected count=2, got %d", count)
	}
	if !strings.Contains(block, "fact one") || !strings.Contains(block, "fact two") {
		t.Errorf("block missing expected content: %s", block)
	}
	if !strings.Contains(block, "RETRIEVED HISTORICAL CONTEXT") {
		t.Error("block missing header")
	}
	if !strings.Contains(block, "STALE OR OUTDATED") {
		t.Error("block missing staleness warning")
	}
}

func TestFormatRAGBlock_Empty(t *testing.T) {
	block, count := memory.FormatRAGBlock(nil)
	if count != 0 || block != "" {
		t.Errorf("expected empty block and 0 count, got %q / %d", block, count)
	}
}
