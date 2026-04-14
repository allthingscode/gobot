//nolint:testpackage // requires unexported mock types for testing
package agent

import (
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
)

// makeMessages creates n alternating user/assistant messages starting with startRole.
func makeMessages(n int, startRole agentctx.MessageRole) []agentctx.StrategicMessage {
	msgs := make([]agentctx.StrategicMessage, n)
	roles := []agentctx.MessageRole{agentctx.RoleUser, agentctx.RoleAssistant}
	startIdx := 0
	if startRole == agentctx.RoleAssistant {
		startIdx = 1
	}
	now := time.Now()
	for i := range msgs {
		msgs[i] = agentctx.StrategicMessage{
			Role:      roles[(startIdx+i)%2],
			CreatedAt: now.Add(time.Duration(i) * time.Second).Format(time.RFC3339),
		}
	}
	return msgs
}

func TestCompactMessages(t *testing.T) {
	t.Parallel()
	for _, tt := range getCompactionTestCases() {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			msgs := makeMessages(tt.msgCount, tt.startRole)
			got, dropped, _ := CompactMessages(msgs, tt.maxN, tt.keepN, config.CompactionPolicyConfig{}, config.ContextPruningConfig{})

			validateCompactResult(t, tt, got, dropped)
		})
	}
}

type compactTestCase struct {
	name        string
	msgCount    int
	startRole   agentctx.MessageRole
	maxN        int
	keepN       int
	wantDropped int
	wantLen     int
}

func getCompactionTestCases() []compactTestCase {
	return []compactTestCase{
		{
			name:        "below threshold",
			msgCount:    10,
			startRole:   agentctx.RoleUser,
			maxN:        50,
			keepN:       20,
			wantDropped: 0,
			wantLen:     10,
		},
		{
			name:        "at threshold",
			msgCount:    50,
			startRole:   agentctx.RoleUser,
			maxN:        50,
			keepN:       20,
			wantDropped: 0,
			wantLen:     50,
		},
		{
			name:      "one over threshold",
			msgCount:  51,
			startRole: agentctx.RoleAssistant,
			maxN:      50,
			keepN:     20,
			// assistant-start: index 31 = "user" → no assistant-strip after keepN slice.
			wantDropped: 31,
			wantLen:     20,
		},
		{
			name:        "large session",
			msgCount:    100,
			startRole:   agentctx.RoleUser,
			maxN:        50,
			keepN:       20,
			wantDropped: 80,
			wantLen:     20,
		},
		{
			name:        "keepN zero",
			msgCount:    10,
			startRole:   agentctx.RoleUser,
			maxN:        50,
			keepN:       0,
			wantDropped: 0,
			wantLen:     10,
		},
		{
			name:        "maxN zero",
			msgCount:    10,
			startRole:   agentctx.RoleUser,
			maxN:        0,
			keepN:       20,
			wantDropped: 0,
			wantLen:     10,
		},
		{
			name:        "empty messages",
			msgCount:    0,
			startRole:   agentctx.RoleUser,
			maxN:        50,
			keepN:       20,
			wantDropped: 0,
			wantLen:     0,
		},
		{
			name:      "keepN >= maxN",
			msgCount:  60,
			startRole: agentctx.RoleUser,
			maxN:      50,
			keepN:     50,
			// keepN clamped to 49; 60 > 50 triggers; last 49 taken from 60-msg slice.
			// messages alternate user/assistant starting with user.
			// message[60-49]=message[11] is "assistant" (index 11, even offset from start=user),
			// so it gets dropped: result len = 48.
			wantDropped: -1,
			wantLen:     -1,
		},
	}
}

func validateCompactResult(t *testing.T, tt compactTestCase, got []agentctx.StrategicMessage, dropped int) {
	t.Helper()
	if tt.wantDropped == -1 {
		// Sentinel: just verify compaction occurred.
		if dropped <= 0 {
			t.Errorf("expected dropped > 0, got %d", dropped)
		}
		if len(got) >= tt.msgCount {
			t.Errorf("expected len(got) < %d, got %d", tt.msgCount, len(got))
		}
		return
	}
	if dropped != tt.wantDropped {
		t.Errorf("dropped = %d, want %d", dropped, tt.wantDropped)
	}
	if len(got) != tt.wantLen {
		t.Errorf("len(got) = %d, want %d", len(got), tt.wantLen)
	}
}

// TestCompactMessages_FirstRetainedAssistant verifies that when the first retained
// message after slicing is an assistant turn, it is dropped.
func TestCompactMessages_FirstRetainedAssistant(t *testing.T) {
	t.Parallel()
	// Build 60 messages alternating user/assistant starting with user.
	// With keepN=10, maxN=50: slice starts at index 50.
	// Index 50 in a user-start alternation: even indices are user, odd are assistant.
	// Index 50 is even → role "user". So we need to start with "assistant" to force
	// the first retained to be "assistant".
	//
	// Start with "assistant": index 0=assistant, 1=user, 2=assistant, ...
	// With keepN=10, slice starts at index 50 → index 50 is even → "assistant".
	msgs := makeMessages(60, agentctx.RoleAssistant)

	got, dropped, _ := CompactMessages(msgs, 50, 10, config.CompactionPolicyConfig{}, config.ContextPruningConfig{})

	// First retained (index 50) is "assistant" → dropped.
	// 60 - 10 = 50 dropped for compaction, then 1 more for assistant stripping = 51.
	if len(got) != 9 {
		t.Errorf("len(got) = %d, want 9", len(got))
	}
	if dropped != 51 {
		t.Errorf("dropped = %d, want 51", dropped)
	}
	if got[0].Role != agentctx.RoleUser {
		t.Errorf("got[0].Role = %q, want %q", got[0].Role, agentctx.RoleUser)
	}
}

// TestCompactMessages_StartsWithUser verifies after compaction the result
// always starts with a user turn in a realistic alternating conversation.
func TestCompactMessages_StartsWithUser(t *testing.T) {
	t.Parallel()
	// 60-message conversation alternating user/assistant starting with user.
	// keepN=10, maxN=50 → slice starts at index 50.
	// Index 50 (even, user-start) → role "user". No assistant-drop needed.
	msgs := makeMessages(60, agentctx.RoleUser)

	got, _, _ := CompactMessages(msgs, 50, 10, config.CompactionPolicyConfig{}, config.ContextPruningConfig{})

	if len(got) == 0 {
		t.Fatal("expected non-empty result")
	}
	if got[0].Role != agentctx.RoleUser {
		t.Errorf("result[0].Role = %q, want %q", got[0].Role, agentctx.RoleUser)
	}
}

func TestPruneMessages(t *testing.T) {
	t.Parallel()
	now := time.Now()
	type pruneCase struct {
		name        string
		msgs        []agentctx.StrategicMessage
		cfg         config.ContextPruningConfig
		wantLen     int
		wantDropped int
	}
	tests := []pruneCase{
		{"no pruning policy", []agentctx.StrategicMessage{
			{Role: agentctx.RoleUser, CreatedAt: now.Add(-1 * time.Hour).Format(time.RFC3339)},
			{Role: agentctx.RoleAssistant, CreatedAt: now.Add(-30 * time.Minute).Format(time.RFC3339)},
		}, config.ContextPruningConfig{}, 2, 0},
		{"TTL pruning - all within TTL", []agentctx.StrategicMessage{
			{Role: agentctx.RoleUser, CreatedAt: now.Add(-1 * time.Hour).Format(time.RFC3339)},
			{Role: agentctx.RoleAssistant, CreatedAt: now.Add(-30 * time.Minute).Format(time.RFC3339)},
		}, config.ContextPruningConfig{TTL: "6h"}, 2, 0},
		{"TTL pruning - some outside TTL", []agentctx.StrategicMessage{
			{Role: agentctx.RoleUser, CreatedAt: now.Add(-10 * time.Hour).Format(time.RFC3339)},
			{Role: agentctx.RoleAssistant, CreatedAt: now.Add(-9 * time.Hour).Format(time.RFC3339)},
			{Role: agentctx.RoleUser, CreatedAt: now.Add(-1 * time.Hour).Format(time.RFC3339)},
			{Role: agentctx.RoleAssistant, CreatedAt: now.Add(-30 * time.Minute).Format(time.RFC3339)},
		}, config.ContextPruningConfig{TTL: "6h"}, 2, 2},
		{"KeepLastAssistants only", []agentctx.StrategicMessage{
			{Role: agentctx.RoleUser, CreatedAt: now.Add(-10 * time.Hour).Format(time.RFC3339)},
			{Role: agentctx.RoleAssistant, CreatedAt: now.Add(-9 * time.Hour).Format(time.RFC3339)},
		}, config.ContextPruningConfig{KeepLastAssistants: 1}, 2, 0},
		{"TTL + KeepLastAssistants", []agentctx.StrategicMessage{
			{Role: agentctx.RoleUser, CreatedAt: now.Add(-10 * time.Hour).Format(time.RFC3339)},
			{Role: agentctx.RoleAssistant, CreatedAt: now.Add(-9 * time.Hour).Format(time.RFC3339)},
			{Role: agentctx.RoleAssistant, CreatedAt: now.Add(-8 * time.Hour).Format(time.RFC3339)},
			{Role: agentctx.RoleUser, CreatedAt: now.Add(-1 * time.Hour).Format(time.RFC3339)},
		}, config.ContextPruningConfig{TTL: "6h", KeepLastAssistants: 2}, 4, 0},
		{"Legacy messages (no timestamp)", []agentctx.StrategicMessage{
			{Role: agentctx.RoleUser},
			{Role: agentctx.RoleAssistant, CreatedAt: now.Add(-30 * time.Minute).Format(time.RFC3339)},
		}, config.ContextPruningConfig{TTL: "6h"}, 2, 0},
		{"Invalid TTL string", []agentctx.StrategicMessage{
			{Role: agentctx.RoleUser, CreatedAt: now.Add(-10 * time.Hour).Format(time.RFC3339)},
		}, config.ContextPruningConfig{TTL: "invalid"}, 1, 0},
		{"Strip multiple leading assistants", []agentctx.StrategicMessage{
			{Role: agentctx.RoleAssistant, CreatedAt: now.Add(-1 * time.Hour).Format(time.RFC3339)},
			{Role: agentctx.RoleAssistant, CreatedAt: now.Add(-50 * time.Minute).Format(time.RFC3339)},
			{Role: agentctx.RoleAssistant, CreatedAt: now.Add(-40 * time.Minute).Format(time.RFC3339)},
			{Role: agentctx.RoleUser, CreatedAt: now.Add(-30 * time.Minute).Format(time.RFC3339)},
		}, config.ContextPruningConfig{TTL: "6h"}, 1, 3},
		{"Empty resulting context", []agentctx.StrategicMessage{
			{Role: agentctx.RoleUser, CreatedAt: now.Add(-10 * time.Hour).Format(time.RFC3339)},
			{Role: agentctx.RoleAssistant, CreatedAt: now.Add(-9 * time.Hour).Format(time.RFC3339)},
		}, config.ContextPruningConfig{TTL: "6h"}, 0, 2},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got, dropped := PruneMessages(tt.msgs, tt.cfg)
			if len(got) != tt.wantLen {
				t.Errorf("len(got) = %d, want %d", len(got), tt.wantLen)
			}
			if dropped != tt.wantDropped {
				t.Errorf("dropped = %d, want %d", dropped, tt.wantDropped)
			}
			if len(got) > 0 && (got[0].Role == agentctx.RoleAssistant || got[0].Role == agentctx.RoleModel) {
				t.Errorf("result starts with assistant/model")
			}
		})
	}
}

// TestCompactMessages_DroppedMessageIdentification verifies that dropped messages
// are correctly identified via the keep[] array, not by assuming they are at the front.
// This is the test for bug B-031.
func TestCompactMessages_DroppedMessageIdentification(t *testing.T) {
	t.Parallel()
	msgs := makeMessages(60, agentctx.RoleUser)

	compacted, dropped, keep := CompactMessages(msgs, 50, 10, config.CompactionPolicyConfig{}, config.ContextPruningConfig{})

	validateKeepArray(t, keep, dropped)
	validateCompactedInOriginal(t, compacted, msgs, keep)
	validateDroppedScattered(t, keep)
}

func validateKeepArray(t *testing.T, keep []bool, expectedDropped int) {
	t.Helper()
	if len(keep) != 60 {
		t.Errorf("keep array length = %d, want 60", len(keep))
	}

	droppedCount := 0
	for _, k := range keep {
		if !k {
			droppedCount++
		}
	}
	if droppedCount != expectedDropped {
		t.Errorf("dropped count from keep[] = %d, but returned dropped = %d", droppedCount, expectedDropped)
	}
}

func validateCompactedInOriginal(t *testing.T, compacted, original []agentctx.StrategicMessage, keep []bool) {
	t.Helper()
	for i, msg := range compacted {
		found := false
		for j := range original {
			if keep[j] && original[j].Role == msg.Role && original[j].CreatedAt == msg.CreatedAt {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("compacted[%d] not found in original kept messages", i)
		}
	}
}

func validateDroppedScattered(t *testing.T, keep []bool) {
	t.Helper()
	allLastTenKept := true
	for i := 50; i < 60; i++ {
		if !keep[i] {
			allLastTenKept = false
			break
		}
	}
	if !allLastTenKept {
		t.Error("expected last 10 messages (indices 50-59) to be kept")
	}
}

// TestPruneMessages_NoTTLKeepLastAssistants verifies B-032: when TTL is empty but
// KeepLastAssistants > 0, PruneMessages must return all messages unchanged.
// Previously the keep[] array was populated with only assistants before an early return;
// removing that guard would have silently dropped all non-assistant messages.
func TestPruneMessages_NoTTLKeepLastAssistants(t *testing.T) {
	t.Parallel()
	now := time.Now()

	tests := []struct {
		name               string
		msgs               []agentctx.StrategicMessage
		keepLastAssistants int
	}{
		{
			name: "mixed conversation preserved when no TTL",
			msgs: []agentctx.StrategicMessage{
				{Role: agentctx.RoleUser, CreatedAt: now.Add(-5 * time.Hour).Format(time.RFC3339)},
				{Role: agentctx.RoleAssistant, CreatedAt: now.Add(-4 * time.Hour).Format(time.RFC3339)},
				{Role: agentctx.RoleUser, CreatedAt: now.Add(-3 * time.Hour).Format(time.RFC3339)},
				{Role: agentctx.RoleAssistant, CreatedAt: now.Add(-2 * time.Hour).Format(time.RFC3339)},
				{Role: agentctx.RoleUser, CreatedAt: now.Add(-1 * time.Hour).Format(time.RFC3339)},
			},
			keepLastAssistants: 1,
		},
		{
			name: "all non-assistant messages preserved when no TTL",
			msgs: []agentctx.StrategicMessage{
				{Role: agentctx.RoleUser, CreatedAt: now.Add(-10 * time.Hour).Format(time.RFC3339)},
				{Role: agentctx.RoleUser, CreatedAt: now.Add(-8 * time.Hour).Format(time.RFC3339)},
				{Role: agentctx.RoleAssistant, CreatedAt: now.Add(-6 * time.Hour).Format(time.RFC3339)},
				{Role: agentctx.RoleUser, CreatedAt: now.Add(-4 * time.Hour).Format(time.RFC3339)},
				{Role: agentctx.RoleUser, CreatedAt: now.Add(-2 * time.Hour).Format(time.RFC3339)},
			},
			keepLastAssistants: 2,
		},
		{
			name: "KeepLastAssistants=0 also no-ops without TTL",
			msgs: []agentctx.StrategicMessage{
				{Role: agentctx.RoleUser, CreatedAt: now.Add(-1 * time.Hour).Format(time.RFC3339)},
				{Role: agentctx.RoleAssistant, CreatedAt: now.Add(-30 * time.Minute).Format(time.RFC3339)},
			},
			keepLastAssistants: 0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			cfg := config.ContextPruningConfig{KeepLastAssistants: tt.keepLastAssistants}
			got, dropped := PruneMessages(tt.msgs, cfg)

			if dropped != 0 {
				t.Errorf("dropped = %d, want 0: PruneMessages must be a no-op when TTL is empty", dropped)
			}
			if len(got) != len(tt.msgs) {
				t.Errorf("len(got) = %d, want %d: all messages must be preserved when TTL is empty", len(got), len(tt.msgs))
			}
		})
	}
}

// ptr returns a pointer to the given string.
func ptr(s string) *string { return &s }

// TestCompactMessages_ToolChainConsistency verifies B-033: tool-call/response
// pairs are not split across the compaction boundary. The compaction pass must
// either keep both halves of a tool-call pair or drop them together so the
// resulting message list never contains an orphaned tool result with no
// originating call, and vice versa.
func TestCompactMessages_ToolChainConsistency(t *testing.T) {
	t.Parallel()
	type tc struct {
		name                string
		msgs                []agentctx.StrategicMessage
		maxN, keepN         int
		wantNoOrphans       bool
		wantNoUnresolvedIDs bool
		wantLen             int
	}
	tests := []tc{
		{"Mode1", buildMessages(32, []toolScenario{
			{idx: 30, role: agentctx.RoleModel, toolCallIDs: []string{"call_abc"}},
			{idx: 31, role: agentctx.RoleTool, toolCallID: "call_abc"},
		}), 31, 1, true, true, 2},
		{"Mode2", buildMessages(60, []toolScenario{
			{idx: 58, role: agentctx.RoleModel, toolCallIDs: []string{"call_mode2"}},
			{idx: 49, role: agentctx.RoleTool, toolCallID: "call_mode2"},
		}), 50, 10, true, true, 11},
		{"clean", makeMessages(51, agentctx.RoleUser), 50, 20, true, true, 19},
		{"multi-call", buildMessages(33, []toolScenario{
			{idx: 30, role: agentctx.RoleModel, toolCallIDs: []string{"call_1", "call_2"}},
			{idx: 31, role: agentctx.RoleTool, toolCallID: "call_1"},
			{idx: 32, role: agentctx.RoleTool, toolCallID: "call_2"},
		}), 32, 1, true, true, 3},
		{"partial", buildMessages(51, []toolScenario{
			{idx: 49, role: agentctx.RoleModel, toolCallIDs: []string{"call_a", "call_b"}},
			{idx: 50, role: agentctx.RoleTool, toolCallID: "call_a"},
		}), 50, 1, false, false, 2},
		{"Mode2+KLA", buildMessages(60, []toolScenario{
			{idx: 49, role: agentctx.RoleModel, toolCallIDs: []string{"call_keep"}},
			{idx: 50, role: agentctx.RoleTool, toolCallID: "call_keep"},
		}), 50, 10, true, true, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got, _, _ := CompactMessages(tt.msgs, tt.maxN, tt.keepN, config.CompactionPolicyConfig{}, config.ContextPruningConfig{})
			if tt.wantNoOrphans {
				assertNoOrphanedTools(t, got)
			}
			if tt.wantNoUnresolvedIDs {
				assertNoUnresolvedToolCalls(t, got)
			}
			if tt.wantLen > 0 && len(got) != tt.wantLen {
				t.Errorf("len(got) = %d, want %d", len(got), tt.wantLen)
			}
		})
	}
}

// assertNoOrphanedTools ensures every tool message in the result has its
// originating model/assistant turn (with the matching ToolCall id) also present.
func assertNoOrphanedTools(t *testing.T, msgs []agentctx.StrategicMessage) {
	t.Helper()
	calledIDs := collectCalledIDs(msgs)
	for i, m := range msgs {
		if m.Role == agentctx.RoleTool && m.ToolCallID != nil {
			if !calledIDs[*m.ToolCallID] {
				t.Errorf("msg[%d]: orphaned tool response for ToolCallID=%q", i, *m.ToolCallID)
			}
		}
	}
}

// assertNoUnresolvedToolCalls ensures every tool call in the result has a
// corresponding tool response also in the result.
func assertNoUnresolvedToolCalls(t *testing.T, msgs []agentctx.StrategicMessage) {
	t.Helper()
	respondedIDs := collectRespondedIDs(msgs)
	for i, m := range msgs {
		if m.Role == agentctx.RoleModel || m.Role == agentctx.RoleAssistant {
			for _, tc := range m.ToolCalls {
				if tc.ID != "" && !respondedIDs[tc.ID] {
					t.Errorf("msg[%d]: unresolved tool call id=%q", i, tc.ID)
				}
			}
		}
	}
}

func collectCalledIDs(msgs []agentctx.StrategicMessage) map[string]bool {
	ids := make(map[string]bool)
	for _, m := range msgs {
		if m.Role == agentctx.RoleModel || m.Role == agentctx.RoleAssistant {
			for _, tc := range m.ToolCalls {
				if tc.ID != "" {
					ids[tc.ID] = true
				}
			}
		}
	}
	return ids
}

func collectRespondedIDs(msgs []agentctx.StrategicMessage) map[string]bool {
	ids := make(map[string]bool)
	for _, m := range msgs {
		if m.Role == agentctx.RoleTool && m.ToolCallID != nil {
			ids[*m.ToolCallID] = true
		}
	}
	return ids
}

// toolScenario describes a single message's tool-related fields for buildMessages.
type toolScenario struct {
	idx         int
	role        agentctx.MessageRole
	toolCallIDs []string // if set, message is model/assistant with these tool calls
	toolCallID  string   // if set (non-empty), message is a tool response
}

// buildMessages creates n messages alternating user/model (starting with "user")
// and applies tool scenarios to specific indices.
func buildMessages(n int, scenarios []toolScenario) []agentctx.StrategicMessage {
	roles := []agentctx.MessageRole{agentctx.RoleUser, agentctx.RoleModel}
	msgs := make([]agentctx.StrategicMessage, n)
	scenarioMap := make(map[int]toolScenario)
	for _, s := range scenarios {
		scenarioMap[s.idx] = s
	}

	now := time.Now()
	for i := 0; i < n; i++ {
		role := roles[i%2]
		msg := agentctx.StrategicMessage{
			Role:      role,
			CreatedAt: now.Add(time.Duration(i) * time.Second).Format(time.RFC3339),
		}
		if s, ok := scenarioMap[i]; ok {
			msg.Role = s.role
			if len(s.toolCallIDs) > 0 {
				msg.ToolCalls = make([]agentctx.ToolCall, len(s.toolCallIDs))
				for j, id := range s.toolCallIDs {
					msg.ToolCalls[j] = agentctx.ToolCall{ID: id}
				}
			}
			if s.toolCallID != "" {
				msg.ToolCallID = ptr(s.toolCallID)
			}
		}
		msgs[i] = msg
	}
	return msgs
}

func TestDefaultConstants(t *testing.T) {
	t.Parallel()
	if DefaultMaxContextMessages <= 0 {
		t.Error("DefaultMaxContextMessages must be positive")
	}
	if DefaultKeepContextMessages <= 0 {
		t.Error("DefaultKeepContextMessages must be positive")
	}
	if DefaultKeepContextMessages >= DefaultMaxContextMessages {
		t.Error("DefaultKeepContextMessages must be less than DefaultMaxContextMessages")
	}
}
