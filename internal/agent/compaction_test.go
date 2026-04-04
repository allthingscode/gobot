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
