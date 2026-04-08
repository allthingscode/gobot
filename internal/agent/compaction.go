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
	if pruning.KeepLastAssistants > 0 {
		assistantsFound := 0
		for i := len(messages) - 1; i >= 0; i-- {
			role := messages[i].Role
			if role == agentctx.RoleAssistant || role == agentctx.RoleModel {
				if assistantsFound < pruning.KeepLastAssistants {
					keep[i] = true
					if i > 0 && messages[i-1].Role == agentctx.RoleUser {
						keep[i-1] = true
					}
					assistantsFound++
				}
			}
		}
	}

	// 3. Tool chain consistency pass: ensure tool-call/response pairs are not split.
	// Build a map of all tool call IDs in the entire message list.
	// Then, after tail-slice/keepLastAssistants have set initial keep[] values, fix splits:
	// 3a: For each kept tool response, if its originating call was dropped, keep the call.
	// 3b: For each kept model/assistant turn with tool calls, ensure all responses are kept.

	// Build a map: callID -> message index of originating call
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

	// 3a: For each kept tool response, if its originating call was dropped, keep the call.
	for i := range messages {
		if !keep[i] {
			continue
		}
		role := messages[i].Role
		if role == agentctx.RoleTool && messages[i].ToolCallID != nil {
			respID := *messages[i].ToolCallID
			if callIdx, exists := allToolCallIDs[respID]; exists {
				// Originating call exists - if it was dropped, keep it now
				if !keep[callIdx] {
					keep[callIdx] = true // complete the chain backward
				}
			}
			// else: no originating call found - leave orphan for now, will be stripped later
		}
	}

	// 3b: For each kept model/assistant turn with tool calls, ensure all responses are kept.
	for i := range messages {
		if !keep[i] {
			continue
		}
		role := messages[i].Role
		if role == agentctx.RoleModel || role == agentctx.RoleAssistant {
			for _, tc := range messages[i].ToolCalls {
				if id, ok := tc["id"].(string); ok && id != "" {
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
		}
	}

	// Construct the compacted list.
	for i, k := range keep {
		if k {
			compacted = append(compacted, messages[i])
		}
	}

	// Gemini requires conversations to start with a user turn.
	// Drop all leading assistant or model turns, but only if doing so won't break tool chains.
	// Check if the first message starts a tool chain - if so, don't strip it.
	if len(compacted) > 0 {
		role := compacted[0].Role
		if role == agentctx.RoleAssistant || role == agentctx.RoleModel {
			// Only strip if this assistant/model turn doesn't have tool calls
			// that are present in the compacted result.
			hasKeptToolCalls := false
			for _, tc := range compacted[0].ToolCalls {
				if id, ok := tc["id"].(string); ok && id != "" {
					// Check if any tool response in compacted matches this call ID
					for _, msg := range compacted[1:] {
						if msg.Role == agentctx.RoleTool && msg.ToolCallID != nil {
							if *msg.ToolCallID == id {
								hasKeptToolCalls = true
								break
							}
						}
					}
				}
				if hasKeptToolCalls {
					break
				}
			}
			// Only strip if this turn doesn't have tool calls that are kept
			if !hasKeptToolCalls {
				compacted = compacted[1:]
			}
		}
	}

	dropped := len(messages) - len(compacted)
	return compacted, dropped, keep
}

// PruneMessages removes messages based on TTL and KeepLastAssistants settings.
func PruneMessages(messages []agentctx.StrategicMessage, cfg config.ContextPruningConfig) (pruned []agentctx.StrategicMessage, droppedCount int) {
	if cfg.TTL == "" && cfg.KeepLastAssistants <= 0 {
		return messages, 0
	}

	var ttl time.Duration
	if cfg.TTL != "" {
		var err error
		ttl, err = time.ParseDuration(cfg.TTL)
		if err != nil {
			slog.Warn("agent: invalid context pruning TTL", "ttl", cfg.TTL, "err", err)
			return messages, 0
		}
	}

	// If TTL is not configured (or parses to zero), TTL-based pruning is disabled.
	// KeepLastAssistants is a safety net during TTL pruning only, not a standalone pruning policy.
	if ttl <= 0 {
		return messages, 0
	}

	now := time.Now()
	cutoff := now.Add(-ttl)

	// Identify messages to keep.
	// 1. Messages newer than cutoff.
	// 2. The last N assistant messages (and their preceding user message) as a safety net.

	keep := make([]bool, len(messages))
	assistantsFound := 0

	// Scan backwards to find the last N assistants.
	if cfg.KeepLastAssistants > 0 {
		for i := len(messages) - 1; i >= 0; i-- {
			role := messages[i].Role
			if role == agentctx.RoleAssistant || role == agentctx.RoleModel {
				if assistantsFound < cfg.KeepLastAssistants {
					keep[i] = true
					// Keep the preceding message if it's a user turn, to satisfy the
					// "must start with user" requirement and avoid stripping.
					if i > 0 && messages[i-1].Role == agentctx.RoleUser {
						keep[i-1] = true
					}
					assistantsFound++
				}
			}
		}
	}

	// Scan forwards for TTL.
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

	for i, k := range keep {
		if k {
			pruned = append(pruned, messages[i])
		}
	}

	// Gemini requires conversations to start with a user turn.
	for len(pruned) > 0 {
		role := pruned[0].Role
		if role == agentctx.RoleAssistant || role == agentctx.RoleModel {
			pruned = pruned[1:]
		} else {
			break
		}
	}

	droppedCount = len(messages) - len(pruned)
	return pruned, droppedCount
}
