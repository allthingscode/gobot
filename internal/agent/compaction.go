package agent

import agentctx "github.com/allthingscode/gobot/internal/context"

// DefaultMaxContextMessages is the message count above which compaction triggers.
const DefaultMaxContextMessages = 50

// DefaultKeepContextMessages is the number of recent messages to retain after compaction.
const DefaultKeepContextMessages = 20

// CompactMessages trims messages to at most keepN entries when len(messages) exceeds maxN.
//
// Algorithm:
//  1. If len(messages) <= maxN: return messages unchanged, dropped=0.
//  2. Take the last keepN messages.
//  3. If the first retained message has role "assistant" or "model", drop it
//     (Gemini requires conversations to start with a user turn).
//  4. Return (compacted, dropped) where dropped = len(messages) - len(compacted).
//
// The returned slice shares the underlying array with messages — callers must
// not mutate the original slice after calling CompactMessages.
func CompactMessages(messages []agentctx.StrategicMessage, maxN, keepN int) ([]agentctx.StrategicMessage, int) {
	// Defensive: invalid parameters — return unchanged.
	if maxN <= 0 || keepN <= 0 {
		return messages, 0
	}

	// If not over the threshold, nothing to do.
	if len(messages) <= maxN {
		return messages, 0
	}

	// Clamp keepN so compaction always drops at least 1 message when triggered.
	if keepN >= maxN {
		keepN = maxN - 1
	}

	// Take the last keepN messages.
	start := len(messages) - keepN
	if start < 0 {
		start = 0
	}
	compacted := messages[start:]

	// Gemini requires conversations to start with a user turn.
	// Drop the first retained message if it is an assistant or model turn.
	if len(compacted) > 0 {
		role := compacted[0].Role
		if role == "assistant" || role == "model" {
			compacted = compacted[1:]
		}
	}

	dropped := len(messages) - len(compacted)
	return compacted, dropped
}
