package agent

import (
	"log/slog"
	"time"

	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
)

// DefaultMaxCompactionInputBytes is the byte-length cap for the string accumulator
// during compaction summarization to prevent OOM on massive context windows.
const DefaultMaxCompactionInputBytes = 512 * 1024 // 512KB

// CompactMessages trims messages to at most keepN entries when len(messages) exceeds maxN.
// It respects the CompactionPolicyConfig strategy and ContextPruningConfig safety nets.
// Returns (compacted messages, count of dropped, keep array from original messages).
func CompactMessages(messages []agentctx.StrategicMessage, maxN, keepN int, _ config.CompactionPolicyConfig, pruning config.ContextPruningConfig) (compacted []agentctx.StrategicMessage, droppedCount int, keepArray []bool) {
	// Defensive: invalid parameters — return unchanged.
	if maxN <= 0 || keepN <= 0 {
		return messages, 0, nil
	}

	// If not over the threshold, nothing to do.
	if len(messages) <= maxN {
		return messages, 0, nil
	}

	// Clamp keepN so compaction always drops at least 1 message when triggered.
	if keepN >= maxN {
		keepN = maxN - 1
	}
	if keepN < 1 {
		keepN = 1
	}

	// Identify messages to keep.
	keep := make([]bool, len(messages))

	// 1. Always keep the last keepN messages.
	start := len(messages) - keepN
	for i := start; i < len(messages); i++ {
		keep[i] = true
	}

	// 2. Safety net: keep the last N assistants (and their preceding user turn).
	applyKeepLastAssistants(messages, keep, pruning.KeepLastAssistants)

	// 3. Tool chain consistency pass: ensure tool-call/response pairs are not split.
	applyToolChainConsistency(messages, keep)

	// Construct the compacted list.
	for i, k := range keep {
		if k {
			compacted = append(compacted, messages[i])
		}
	}

	// Gemini requires conversations to start with a user turn.
	compacted = stripLeadingAssistantTurns(compacted)

	dropped := len(messages) - len(compacted)
	return compacted, dropped, keep
}

func applyKeepLastAssistants(messages []agentctx.StrategicMessage, keep []bool, keepLastAssistants int) {
	if keepLastAssistants <= 0 {
		return
	}
	assistantsFound := 0
	for i := len(messages) - 1; i >= 0; i-- {
		role := messages[i].Role
		if role == agentctx.RoleAssistant || role == agentctx.RoleModel {
			if assistantsFound < keepLastAssistants {
				keep[i] = true
				if i > 0 && messages[i-1].Role == agentctx.RoleUser {
					keep[i-1] = true
				}
				assistantsFound++
			}
		}
	}
}

func applyToolChainConsistency(messages []agentctx.StrategicMessage, keep []bool) {
	// Build a map: callID -> message index of originating call
	allToolCallIDs := buildToolCallMap(messages)

	// 3a: For each kept tool response, if its originating call was dropped, keep the call.
	completeChainsBackward(messages, keep, allToolCallIDs)

	// 3b: For each kept model/assistant turn with tool calls, ensure all responses are kept.
	completeChainsForward(messages, keep)
}

func buildToolCallMap(messages []agentctx.StrategicMessage) map[string]int {
	allToolCallIDs := make(map[string]int)
	for i := range messages {
		role := messages[i].Role
		if role == agentctx.RoleModel || role == agentctx.RoleAssistant {
			for _, tc := range messages[i].ToolCalls {
				if id, ok := tc["id"].(string); ok && id != "" {
					allToolCallIDs[id] = i
				}
			}
		}
	}
	return allToolCallIDs
}

func completeChainsBackward(messages []agentctx.StrategicMessage, keep []bool, allToolCallIDs map[string]int) {
	for i := range messages {
		if !keep[i] {
			continue
		}
		if messages[i].Role == agentctx.RoleTool && messages[i].ToolCallID != nil {
			respID := *messages[i].ToolCallID
			if callIdx, exists := allToolCallIDs[respID]; exists {
				if !keep[callIdx] {
					keep[callIdx] = true // complete the chain backward
				}
			}
		}
	}
}

func completeChainsForward(messages []agentctx.StrategicMessage, keep []bool) {
	for i := range messages {
		if !keep[i] {
			continue
		}
		role := messages[i].Role
		if role == agentctx.RoleModel || role == agentctx.RoleAssistant {
			keepResponsesForCall(messages, keep, messages[i].ToolCalls)
		}
	}
}

func keepResponsesForCall(messages []agentctx.StrategicMessage, keep []bool, toolCalls []map[string]any) {
	for _, tc := range toolCalls {
		id, ok := tc["id"].(string)
		if !ok || id == "" {
			continue
		}
		// Find all tool responses for this call ID and keep them
		for j := range messages {
			if messages[j].Role == agentctx.RoleTool && messages[j].ToolCallID != nil {
				if *messages[j].ToolCallID == id {
					keep[j] = true
				}
			}
		}
	}
}


func stripLeadingAssistantTurns(compacted []agentctx.StrategicMessage) []agentctx.StrategicMessage {
	if len(compacted) == 0 {
		return compacted
	}

	role := compacted[0].Role
	if role != agentctx.RoleAssistant && role != agentctx.RoleModel {
		return compacted
	}

	if hasKeptToolCalls(compacted) {
		return compacted
	}

	return compacted[1:]
}

func hasKeptToolCalls(compacted []agentctx.StrategicMessage) bool {
	if len(compacted) == 0 {
		return false
	}
	for _, tc := range compacted[0].ToolCalls {
		id, ok := tc["id"].(string)
		if !ok || id == "" {
			continue
		}
		// Check if any tool response in compacted matches this call ID
		for _, msg := range compacted[1:] {
			if msg.Role == agentctx.RoleTool && msg.ToolCallID != nil {
				if *msg.ToolCallID == id {
					return true
				}
			}
		}
	}
	return false
}

// PruneMessages removes messages based on TTL and KeepLastAssistants settings.
func PruneMessages(messages []agentctx.StrategicMessage, cfg config.ContextPruningConfig) (pruned []agentctx.StrategicMessage, droppedCount int) {
	if cfg.TTL == "" && cfg.KeepLastAssistants <= 0 {
		return messages, 0
	}

	ttl, ok := parseTTL(cfg.TTL)
	if !ok || ttl <= 0 {
		return messages, 0
	}

	cutoff := time.Now().Add(-ttl)
	keep := make([]bool, len(messages))

	// 1. Keep the last N assistant messages (and their preceding user message) as a safety net.
	applyKeepLastAssistants(messages, keep, cfg.KeepLastAssistants)

	// 2. Keep messages newer than cutoff.
	applyTTLPruning(messages, keep, cutoff)

	for i, k := range keep {
		if k {
			pruned = append(pruned, messages[i])
		}
	}

	// Gemini requires conversations to start with a user turn.
	pruned = ensureStartsAndEndsWithUser(pruned) // Simplified name but following logic

	droppedCount = len(messages) - len(pruned)
	return pruned, droppedCount
}

func parseTTL(ttlStr string) (time.Duration, bool) {
	if ttlStr == "" {
		return 0, true
	}
	ttl, err := time.ParseDuration(ttlStr)
	if err != nil {
		slog.Warn("agent: invalid context pruning TTL", "ttl", ttlStr, "err", err)
		return 0, false
	}
	return ttl, true
}

func applyTTLPruning(messages []agentctx.StrategicMessage, keep []bool, cutoff time.Time) {
	for i, msg := range messages {
		if msg.CreatedAt == "" {
			// Legacy messages without a timestamp are kept to avoid silent data loss.
			keep[i] = true
			continue
		}
		t, err := time.Parse(time.RFC3339, msg.CreatedAt)
		if err != nil {
			keep[i] = true // keep if timestamp is unparseable
			continue
		}
		if t.After(cutoff) {
			keep[i] = true
		}
	}
}

func ensureStartsAndEndsWithUser(pruned []agentctx.StrategicMessage) []agentctx.StrategicMessage {
	for len(pruned) > 0 {
		role := pruned[0].Role
		if role == agentctx.RoleAssistant || role == agentctx.RoleModel {
			pruned = pruned[1:]
		} else {
			break
		}
	}
	return pruned
}

