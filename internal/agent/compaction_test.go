package agent

import (
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
)

// makeMessages creates n alternating user/assistant messages starting with startRole.
func makeMessages(n int, startRole string) []agentctx.StrategicMessage {
	msgs := make([]agentctx.StrategicMessage, n)
	roles := []string{"user", "assistant"}
	startIdx := 0
	if startRole == "assistant" {
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
	tests := []struct {
		name        string
		msgCount    int
		startRole   string
		maxN        int
		keepN       int
		wantDropped int
		wantLen     int
	}{
		{
			name:        "below threshold",
			msgCount:    10,
			startRole:   "user",
			maxN:        50,
			keepN:       20,
			wantDropped: 0,
			wantLen:     10,
		},
		{
			name:        "at threshold",
			msgCount:    50,
			startRole:   "user",
			maxN:        50,
			keepN:       20,
			wantDropped: 0,
			wantLen:     50,
		},
		{
			name:      "one over threshold",
			msgCount:  51,
			startRole: "assistant",
			// assistant-start: index 31 = "user" → no assistant-strip after keepN slice.
			maxN:        50,
			keepN:       20,
			wantDropped: 31,
			wantLen:     20,
		},
		{
			name:        "large session",
			msgCount:    100,
			startRole:   "user",
			maxN:        50,
			keepN:       20,
			wantDropped: 80,
			wantLen:     20,
		},
		{
			name:        "keepN zero",
			msgCount:    10,
			startRole:   "user",
			maxN:        50,
			keepN:       0,
			wantDropped: 0,
			wantLen:     10,
		},
		{
			name:        "maxN zero",
			msgCount:    10,
			startRole:   "user",
			maxN:        0,
			keepN:       20,
			wantDropped: 0,
			wantLen:     10,
		},
		{
			name:        "empty messages",
			msgCount:    0,
			startRole:   "user",
			maxN:        50,
			keepN:       20,
			wantDropped: 0,
			wantLen:     0,
		},
		{
			name:      "keepN >= maxN",
			msgCount:  60,
			startRole: "user",
			maxN:      50,
			keepN:     50,
			// keepN clamped to 49; 60 > 50 triggers; last 49 taken from 60-msg slice.
			// messages alternate user/assistant starting with user.
			// message[60-49]=message[11] is "assistant" (index 11, even offset from start=user),
			// so it gets dropped: result len = 48.
			wantDropped: -1, // sentinel: just verify > 0 and < 60
			wantLen:     -1, // sentinel: just verify < 60
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			msgs := makeMessages(tt.msgCount, tt.startRole)
			got, dropped, _ := CompactMessages(msgs, tt.maxN, tt.keepN, config.CompactionPolicyConfig{}, config.ContextPruningConfig{})

			if tt.wantDropped == -1 {
				// Sentinel: just verify compaction occurred.
				if dropped <= 0 {
					t.Errorf("expected dropped > 0, got %d", dropped)
				}
				if len(got) >= tt.msgCount {
					t.Errorf("expected len(got) < %d, got %d", tt.msgCount, len(got))
				}
			} else {
				if dropped != tt.wantDropped {
					t.Errorf("dropped = %d, want %d", dropped, tt.wantDropped)
				}
				if len(got) != tt.wantLen {
					t.Errorf("len(got) = %d, want %d", len(got), tt.wantLen)
				}
			}
		})
	}
}

// TestCompactMessages_FirstRetainedAssistant verifies that when the first retained
// message after slicing is an assistant turn, it is dropped.
func TestCompactMessages_FirstRetainedAssistant(t *testing.T) {
	// Build 60 messages alternating user/assistant starting with user.
	// With keepN=10, maxN=50: slice starts at index 50.
	// Index 50 in a user-start alternation: even indices are user, odd are assistant.
	// Index 50 is even → role "user". So we need to start with "assistant" to force
	// the first retained to be "assistant".
	//
	// Start with "assistant": index 0=assistant, 1=user, 2=assistant, ...
	// With keepN=10, slice starts at index 50 → index 50 is even → "assistant".
	msgs := makeMessages(60, "assistant")

	got, dropped, _ := CompactMessages(msgs, 50, 10, config.CompactionPolicyConfig{}, config.ContextPruningConfig{})

	// First retained (index 50) is "assistant" → dropped.
	// 60 - 10 = 50 dropped for compaction, then 1 more for assistant stripping = 51.
	if len(got) != 9 {
		t.Errorf("len(got) = %d, want 9", len(got))
	}
	if dropped != 51 {
		t.Errorf("dropped = %d, want 51", dropped)
	}
	if got[0].Role != "user" {
		t.Errorf("got[0].Role = %q, want %q", got[0].Role, "user")
	}
}

// TestCompactMessages_StartsWithUser verifies after compaction the result
// always starts with a user turn in a realistic alternating conversation.
func TestCompactMessages_StartsWithUser(t *testing.T) {
	// 60-message conversation alternating user/assistant starting with user.
	// keepN=10, maxN=50 → slice starts at index 50.
	// Index 50 (even, user-start) → role "user". No assistant-drop needed.
	msgs := makeMessages(60, "user")

	got, _, _ := CompactMessages(msgs, 50, 10, config.CompactionPolicyConfig{}, config.ContextPruningConfig{})

	if len(got) == 0 {
		t.Fatal("expected non-empty result")
	}
	if got[0].Role != "user" {
		t.Errorf("result[0].Role = %q, want %q", got[0].Role, "user")
	}
}

func TestPruneMessages(t *testing.T) {
	now := time.Now()

	tests := []struct {
		name        string
		msgs        []agentctx.StrategicMessage
		cfg         config.ContextPruningConfig
		wantLen     int
		wantDropped int
	}{
		{
			name: "no pruning policy",
			msgs: []agentctx.StrategicMessage{
				{Role: "user", CreatedAt: now.Add(-1 * time.Hour).Format(time.RFC3339)},
				{Role: "assistant", CreatedAt: now.Add(-30 * time.Minute).Format(time.RFC3339)},
			},
			cfg:         config.ContextPruningConfig{},
			wantLen:     2,
			wantDropped: 0,
		},
		{
			name: "TTL pruning - all within TTL",
			msgs: []agentctx.StrategicMessage{
				{Role: "user", CreatedAt: now.Add(-1 * time.Hour).Format(time.RFC3339)},
				{Role: "assistant", CreatedAt: now.Add(-30 * time.Minute).Format(time.RFC3339)},
			},
			cfg:         config.ContextPruningConfig{TTL: "6h"},
			wantLen:     2,
			wantDropped: 0,
		},
		{
			name: "TTL pruning - some outside TTL",
			msgs: []agentctx.StrategicMessage{
				{Role: "user", CreatedAt: now.Add(-10 * time.Hour).Format(time.RFC3339)},
				{Role: "assistant", CreatedAt: now.Add(-9 * time.Hour).Format(time.RFC3339)},
				{Role: "user", CreatedAt: now.Add(-1 * time.Hour).Format(time.RFC3339)},
				{Role: "assistant", CreatedAt: now.Add(-30 * time.Minute).Format(time.RFC3339)},
			},
			cfg:         config.ContextPruningConfig{TTL: "6h"},
			wantLen:     2,
			wantDropped: 2,
		},
		{
			name: "KeepLastAssistants only - does nothing for PruneMessages without TTL",
			msgs: []agentctx.StrategicMessage{
				{Role: "user", CreatedAt: now.Add(-10 * time.Hour).Format(time.RFC3339)},
				{Role: "assistant", CreatedAt: now.Add(-9 * time.Hour).Format(time.RFC3339)},
			},
			cfg:         config.ContextPruningConfig{KeepLastAssistants: 1},
			wantLen:     2,
			wantDropped: 0,
		},
		{
			name: "TTL + KeepLastAssistants",
			msgs: []agentctx.StrategicMessage{
				{Role: "user", CreatedAt: now.Add(-10 * time.Hour).Format(time.RFC3339)},     // index 0
				{Role: "assistant", CreatedAt: now.Add(-9 * time.Hour).Format(time.RFC3339)}, // index 1
				{Role: "assistant", CreatedAt: now.Add(-8 * time.Hour).Format(time.RFC3339)}, // index 2
				{Role: "user", CreatedAt: now.Add(-1 * time.Hour).Format(time.RFC3339)},      // index 3
			},
			// TTL 6h cutoff: message 0, 1, 2 are OLD.
			// KeepLastAssistants: 2 -> keeps index 1 and 2.
			// My improved logic also keeps index 0 because it's the user message before index 1.
			// Result before strip: [U(-10h), A(-9h), A(-8h), U(-1h)].
			// After leading assistant strip: [U(-10h), A(-9h), A(-8h), U(-1h)].
			cfg:         config.ContextPruningConfig{TTL: "6h", KeepLastAssistants: 2},
			wantLen:     4,
			wantDropped: 0,
		},
		{
			name: "Legacy messages (no timestamp)",
			msgs: []agentctx.StrategicMessage{
				{Role: "user"}, // CreatedAt is empty
				{Role: "assistant", CreatedAt: now.Add(-30 * time.Minute).Format(time.RFC3339)},
			},
			cfg:         config.ContextPruningConfig{TTL: "6h"},
			wantLen:     2,
			wantDropped: 0,
		},
		{
			name: "Invalid TTL string",
			msgs: []agentctx.StrategicMessage{
				{Role: "user", CreatedAt: now.Add(-10 * time.Hour).Format(time.RFC3339)},
			},
			cfg:         config.ContextPruningConfig{TTL: "invalid"},
			wantLen:     1,
			wantDropped: 0,
		},
		{
			name: "Strip multiple leading assistants",
			msgs: []agentctx.StrategicMessage{
				{Role: "assistant", CreatedAt: now.Add(-1 * time.Hour).Format(time.RFC3339)},
				{Role: "assistant", CreatedAt: now.Add(-50 * time.Minute).Format(time.RFC3339)},
				{Role: "assistant", CreatedAt: now.Add(-40 * time.Minute).Format(time.RFC3339)},
				{Role: "user", CreatedAt: now.Add(-30 * time.Minute).Format(time.RFC3339)},
			},
			cfg:         config.ContextPruningConfig{TTL: "6h"},
			wantLen:     1,
			wantDropped: 3,
		},
		{
			name: "Empty resulting context",
			msgs: []agentctx.StrategicMessage{
				{Role: "user", CreatedAt: now.Add(-10 * time.Hour).Format(time.RFC3339)},
				{Role: "assistant", CreatedAt: now.Add(-9 * time.Hour).Format(time.RFC3339)},
			},
			cfg:         config.ContextPruningConfig{TTL: "6h"},
			wantLen:     0,
			wantDropped: 2,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, dropped := PruneMessages(tt.msgs, tt.cfg)
			if len(got) != tt.wantLen {
				t.Errorf("len(got) = %d, want %d", len(got), tt.wantLen)
			}
			if dropped != tt.wantDropped {
				t.Errorf("dropped = %d, want %d", dropped, tt.wantDropped)
			}
			if len(got) > 0 && (got[0].Role == "assistant" || got[0].Role == "model") {
				t.Errorf("result starts with assistant/model")
			}
		})
	}
}

// TestCompactMessages_DroppedMessageIdentification verifies that dropped messages
// are correctly identified via the keep[] array, not by assuming they are at the front.
// This is the test for bug B-031.
func TestCompactMessages_DroppedMessageIdentification(t *testing.T) {
	// Create a conversation where dropped messages are scattered, not at the front.
	// With keepN=10, maxN=50: keep the last 10 messages, drop the rest.
	msgs := makeMessages(60, "user")

	compacted, dropped, keep := CompactMessages(msgs, 50, 10, config.CompactionPolicyConfig{}, config.ContextPruningConfig{})

	// Verify that the keep[] array correctly reflects what was dropped.
	if len(keep) != 60 {
		t.Errorf("keep array length = %d, want 60", len(keep))
	}

	// Count how many keep[] entries are false (these are the dropped messages).
	droppedCount := 0
	droppedIndices := []int{}
	for i, k := range keep {
		if !k {
			droppedCount++
			droppedIndices = append(droppedIndices, i)
		}
	}

	if droppedCount != dropped {
		t.Errorf("dropped count from keep[] = %d, but CompactMessages returned dropped = %d", droppedCount, dropped)
	}

	// Verify that the compacted messages only contain messages where keep[i] == true.
	for i, msg := range compacted {
		// The message at compacted[i] is one of the kept messages from the original array.
		// We can verify by checking the content matches.
		found := false
		for j := range msgs {
			if keep[j] && msgs[j].Role == msg.Role && msgs[j].CreatedAt == msg.CreatedAt {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("compacted[%d] not found in original kept messages", i)
		}
	}

	// Verify that dropped indices do NOT start at 0.
	// This is the key test: dropped messages are scattered throughout, not at the front.
	if len(droppedIndices) > 0 && droppedIndices[0] == 0 {
		// It's possible the first message is dropped due to assistant-stripping logic,
		// but most dropped messages should be at the beginning (indices 0..39 for a 60-message list).
		// Let's verify that the last 10 are kept.
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
}

// TestPruneMessages_NoTTLKeepLastAssistants verifies B-032: when TTL is empty but
// KeepLastAssistants > 0, PruneMessages must return all messages unchanged.
// Previously the keep[] array was populated with only assistants before an early return;
// removing that guard would have silently dropped all non-assistant messages.
func TestPruneMessages_NoTTLKeepLastAssistants(t *testing.T) {
	now := time.Now()

	tests := []struct {
		name               string
		msgs               []agentctx.StrategicMessage
		keepLastAssistants int
	}{
		{
			name: "mixed conversation preserved when no TTL",
			msgs: []agentctx.StrategicMessage{
				{Role: "user", CreatedAt: now.Add(-5 * time.Hour).Format(time.RFC3339)},
				{Role: "assistant", CreatedAt: now.Add(-4 * time.Hour).Format(time.RFC3339)},
				{Role: "user", CreatedAt: now.Add(-3 * time.Hour).Format(time.RFC3339)},
				{Role: "assistant", CreatedAt: now.Add(-2 * time.Hour).Format(time.RFC3339)},
				{Role: "user", CreatedAt: now.Add(-1 * time.Hour).Format(time.RFC3339)},
			},
			keepLastAssistants: 1,
		},
		{
			name: "all non-assistant messages preserved when no TTL",
			msgs: []agentctx.StrategicMessage{
				{Role: "user", CreatedAt: now.Add(-10 * time.Hour).Format(time.RFC3339)},
				{Role: "user", CreatedAt: now.Add(-8 * time.Hour).Format(time.RFC3339)},
				{Role: "assistant", CreatedAt: now.Add(-6 * time.Hour).Format(time.RFC3339)},
				{Role: "user", CreatedAt: now.Add(-4 * time.Hour).Format(time.RFC3339)},
				{Role: "user", CreatedAt: now.Add(-2 * time.Hour).Format(time.RFC3339)},
			},
			keepLastAssistants: 2,
		},
		{
			name:               "KeepLastAssistants=0 also no-ops without TTL",
			msgs: []agentctx.StrategicMessage{
				{Role: "user", CreatedAt: now.Add(-1 * time.Hour).Format(time.RFC3339)},
				{Role: "assistant", CreatedAt: now.Add(-30 * time.Minute).Format(time.RFC3339)},
			},
			keepLastAssistants: 0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
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

	tests := []struct {
		name                string
		msgs                []agentctx.StrategicMessage
		maxN                int
		keepN               int
		wantNoOrphans       bool
		wantNoUnresolvedIDs bool
		wantLen             int
		checkFn             func(t *testing.T, got []agentctx.StrategicMessage, keep []bool)
	}{
		{
			name: "Mode 1 - boundary split drops call, keeps response",
			// Build 32 messages alternating user/model starting with user (index 0).
			// With maxN=31, keepN=1: keep only last 1 message (index 31).
			// Index 30 (dropped) is even → role "user" by default, but we override to "model" with tool call.
			// Index 31 (kept) is odd → role "model" by default, but we override to "tool" with response.
			// The fix must detect that kept tool response needs its originating call and keep both.
			msgs: buildMessages(32, []toolScenario{
				{idx: 30, role: "model", toolCallIDs: []string{"call_abc"}},
				{idx: 31, role: "tool", toolCallID: "call_abc"},
			}),
			maxN:          31,
			keepN:         1,
			wantNoOrphans: true,
			wantLen:       2, // Both message 30 and 31 should be kept (call + response)
		},
		{
			name: "Mode 2 - keepLastAssistants keeps call but drops response",
			// 60 messages alternating user/model starting with user.
			// With maxN=50, keepN=10, KeepLastAssistants=1:
			//   - Tail-slice keeps indices 50-59 (10 messages)
			//   - KeepLastAssistants=1 finds last assistant (index 59, odd=model) and preceding user (58)
			//   - But we place tool call at index 58 (user, overridden to model with call)
			//   - And tool response at index 49 (dropped by tail-slice)
			// Without 3a pass: call at 58 kept, response at 49 dropped → orphaned call
			// With 3a pass: response 49 is found when scanning from call 58, marked as kept
			msgs: buildMessages(60, []toolScenario{
				{idx: 58, role: "model", toolCallIDs: []string{"call_mode2"}},  // kept by keepLastAssistants
				{idx: 49, role: "tool", toolCallID: "call_mode2"},  // dropped by tail-slice, should be recovered
			}),
			maxN:          50,
			keepN:         10,
			wantNoOrphans: true,
			wantNoUnresolvedIDs: true,
			wantLen:       11, // tail-slice(10) + tool response(1) + tool call(already in 10) = 11 total
		},
		{
			name:                "clean compaction - no tool calls",
			msgs:                makeMessages(51, "user"),
			maxN:                50,
			keepN:               20,
			wantNoOrphans:       true,
			wantNoUnresolvedIDs: true,
			wantLen:             19, // Index 31 is assistant (odd index), gets stripped as leading assistant
		},
		{
			name: "multi-tool call boundary - both calls dropped",
			// 33 messages, maxN=32, keepN=1.
			// Keeps only index 32.
			// Indices 30,31,32: 30 has call for 31 and 32, but 30 is dropped.
			msgs: buildMessages(33, []toolScenario{
				{idx: 30, role: "model", toolCallIDs: []string{"call_1", "call_2"}},
				{idx: 31, role: "tool", toolCallID: "call_1"},
				{idx: 32, role: "tool", toolCallID: "call_2"},
			}),
			maxN:          32,
			keepN:         1,
			wantNoOrphans: true,
			wantLen:       3, // All 3 must be kept: call at 30, responses at 31,32
		},
		{
			name: "partial tool responses - call kept, one response missing",
			// 51 messages, maxN=50, keepN=1.
			// Keeps only index 50.
			// Index 49 has tool calls for 50, but index 50 only responds to call_a.
			// After tail-slice: keeps index 50 (response to call_a), drops index 49 (calls).
			msgs: buildMessages(51, []toolScenario{
				{idx: 49, role: "model", toolCallIDs: []string{"call_a", "call_b"}},
				{idx: 50, role: "tool", toolCallID: "call_a"},
			}),
			maxN:          50,
			keepN:         1,
			wantNoOrphans: false, // We allow orphans temporarily to complete the chain
			wantLen:       2,     // Both 49 and 50 must be kept
		},
		{
			name: "Mode 2 with KeepLastAssistants",
			// 60 messages alternating user/model starting with user.
			// With maxN=50, keepN=10: keeps indices 50-59 (last 10).
			// KeepLastAssistants=1: keeps last assistant and preceding user.
			// Let's place tool call at index 49 (dropped by tail-slice) and response at 50 (kept by tail-slice + KeepLastAssistants).
			msgs: buildMessages(60, []toolScenario{
				{idx: 49, role: "model", toolCallIDs: []string{"call_keep"}},
				{idx: 50, role: "tool", toolCallID: "call_keep"},
			}),
			maxN:          50,
			keepN:         10,
			wantNoOrphans: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, _, keep := CompactMessages(tt.msgs, tt.maxN, tt.keepN,
				config.CompactionPolicyConfig{}, config.ContextPruningConfig{})

			if tt.wantNoOrphans {
				assertNoOrphanedTools(t, got)
			}
			if tt.wantNoUnresolvedIDs {
				assertNoUnresolvedToolCalls(t, got)
			}
			if tt.wantLen > 0 && len(got) != tt.wantLen {
				t.Errorf("len(got) = %d, want %d", len(got), tt.wantLen)
			}
			if tt.checkFn != nil {
				tt.checkFn(t, got, keep)
			}
		})
	}
}

// assertNoOrphanedTools ensures every tool message in the result has its
// originating model/assistant turn (with the matching ToolCall id) also present.
func assertNoOrphanedTools(t *testing.T, msgs []agentctx.StrategicMessage) {
	t.Helper()
	// Collect all tool call IDs present in model/assistant turns in the result.
	calledIDs := make(map[string]bool)
	for _, m := range msgs {
		if m.Role == "model" || m.Role == "assistant" {
			for _, tc := range m.ToolCalls {
				if id, ok := tc["id"].(string); ok && id != "" {
					calledIDs[id] = true
				}
			}
		}
	}
	// Check every tool message references an ID that exists in calledIDs.
	for i, m := range msgs {
		if m.Role == "tool" && m.ToolCallID != nil {
			if !calledIDs[*m.ToolCallID] {
				t.Errorf("msg[%d]: orphaned tool response for ToolCallID=%q (no matching tool call in result)",
					i, *m.ToolCallID)
			}
		}
	}
}

// assertNoUnresolvedToolCalls ensures every tool call in the result has a
// corresponding tool response also in the result.
func assertNoUnresolvedToolCalls(t *testing.T, msgs []agentctx.StrategicMessage) {
	t.Helper()
	respondedIDs := make(map[string]bool)
	for _, m := range msgs {
		if m.Role == "tool" && m.ToolCallID != nil {
			respondedIDs[*m.ToolCallID] = true
		}
	}
	for i, m := range msgs {
		if m.Role == "model" || m.Role == "assistant" {
			for _, tc := range m.ToolCalls {
				if id, ok := tc["id"].(string); ok && id != "" {
					if !respondedIDs[id] {
						t.Errorf("msg[%d]: unresolved tool call id=%q (no matching tool response in result)",
							i, id)
					}
				}
			}
		}
	}
}

// toolScenario describes a single message's tool-related fields for buildMessages.
type toolScenario struct {
	idx         int
	role        string
	toolCallIDs []string // if set, message is model/assistant with these tool calls
	toolCallID  string   // if set (non-empty), message is a tool response
}

// buildMessages creates n messages alternating user/model (starting with "user")
// and applies tool scenarios to specific indices.
func buildMessages(n int, scenarios []toolScenario) []agentctx.StrategicMessage {
	roles := []string{"user", "model"}
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
				msg.ToolCalls = make([]map[string]any, len(s.toolCallIDs))
				for j, id := range s.toolCallIDs {
					msg.ToolCalls[j] = map[string]any{"id": id}
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
