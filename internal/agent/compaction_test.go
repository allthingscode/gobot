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
			got, dropped := CompactMessages(msgs, tt.maxN, tt.keepN, config.CompactionPolicyConfig{})

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

	got, dropped := CompactMessages(msgs, 50, 10, config.CompactionPolicyConfig{})

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

	got, _ := CompactMessages(msgs, 50, 10, config.CompactionPolicyConfig{})

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
			// Keep set: {1, 2, 3}. Pruned before strip: [A(-9h), A(-8h), U(-1h)].
			// Strip all leading assistants -> [U(-1h)].
			cfg:         config.ContextPruningConfig{TTL: "6h", KeepLastAssistants: 2},
			wantLen:     1,
			wantDropped: 3,
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
