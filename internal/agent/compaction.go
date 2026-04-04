package agent

import (
	"log/slog"
	"time"

	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
)

// DefaultMaxContextMessages is the message count above which compaction triggers.
const DefaultMaxContextMessages = 50

// DefaultKeepContextMessages is the number of recent messages to retain after compaction.
const DefaultKeepContextMessages = 20

// CompactMessages trims messages to at most keepN entries when len(messages) exceeds maxN.
// It respects the CompactionPolicyConfig strategy and ContextPruningConfig safety nets.
func CompactMessages(messages []agentctx.StrategicMessage, maxN, keepN int, policy config.CompactionPolicyConfig, pruning config.ContextPruningConfig) ([]agentctx.StrategicMessage, int) {
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
			if role == "assistant" || role == "model" {
				if assistantsFound < pruning.KeepLastAssistants {
					keep[i] = true
					if i > 0 && messages[i-1].Role == "user" {
						keep[i-1] = true
					}
					assistantsFound++
				}
			}
		}
	}

	// Construct the compacted list.
	var compacted []agentctx.StrategicMessage
	for i, k := range keep {
		if k {
			compacted = append(compacted, messages[i])
		}
	}

	// Gemini requires conversations to start with a user turn.
	// Drop all leading assistant or model turns.
	for len(compacted) > 0 {
		role := compacted[0].Role
		if role == "assistant" || role == "model" {
			compacted = compacted[1:]
		} else {
			break
		}
	}

	dropped := len(messages) - len(compacted)
	return compacted, dropped
}

// PruneMessages removes messages based on TTL and KeepLastAssistants settings.
func PruneMessages(messages []agentctx.StrategicMessage, cfg config.ContextPruningConfig) ([]agentctx.StrategicMessage, int) {
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

	if ttl <= 0 && cfg.KeepLastAssistants <= 0 {
		return messages, 0
	}

	now := time.Now()
	cutoff := now.Add(-ttl)

	// Identify messages to keep.
	// 1. Messages newer than cutoff.
	// 2. The last N assistant messages (and their preceding user message to avoid stripping).

	keep := make([]bool, len(messages))
	assistantsFound := 0

	// Scan backwards to find the last N assistants.
	if cfg.KeepLastAssistants > 0 {
		for i := len(messages) - 1; i >= 0; i-- {
			role := messages[i].Role
			if role == "assistant" || role == "model" {
				if assistantsFound < cfg.KeepLastAssistants {
					keep[i] = true
					// Keep the preceding message if it's a user turn, to satisfy the
					// "must start with user" requirement and avoid stripping.
					if i > 0 && messages[i-1].Role == "user" {
						keep[i-1] = true
					}
					assistantsFound++
				}
			}
		}
	}

	// Scan forwards for TTL and combine with assistants.
	if ttl > 0 {
		for i, msg := range messages {
			if msg.CreatedAt == "" {
				// If no timestamp, keep it to be safe, or treat as "new"?
				// Given it's a new feature, legacy messages won't have it.
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
	} else {
		// If no TTL, we only kept assistants above.
		// But we should probably keep EVERYTHING else if no TTL is set?
		// Wait, if no TTL is set, why are we here?
		// The check `if ttl <= 0 && cfg.KeepLastAssistants <= 0` at the top handles this.
		// If TTL is not set but KeepLastAssistants is, it means we ONLY keep last N assistants?
		// No, that doesn't make sense. Pruning usually means "remove what is OLD".
		// If TTL is NOT set, TTL-based pruning is disabled.
		// If KeepLastAssistants IS set, it's a safety net for OTHER pruning (like count-based).
		// But PruneMessages's primary job is TTL.
		if ttl <= 0 {
			return messages, 0
		}
	}

	var pruned []agentctx.StrategicMessage
	for i, k := range keep {
		if k {
			pruned = append(pruned, messages[i])
		}
	}

	// Gemini requires conversations to start with a user turn.
	for len(pruned) > 0 {
		role := pruned[0].Role
		if role == "assistant" || role == "model" {
			pruned = pruned[1:]
		} else {
			break
		}
	}

	dropped := len(messages) - len(pruned)
	return pruned, dropped
}
