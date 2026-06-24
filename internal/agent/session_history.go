package agent

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"time"

	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/logattr"
	"github.com/allthingscode/gobot/internal/memory"
)

// loadHistory loads conversation history from the provided checkpoint store.
func (m *SessionManager) loadHistory(ctx context.Context, sessionKey string, store CheckpointStore) (messages []agentctx.StrategicMessage, iteration int, stateless bool, err error) {
	if store != nil {
		snap, loadErr := store.LoadLatest(ctx, sessionKey)
		if loadErr == nil && snap != nil {
			messages = snap.Messages
			iteration = snap.Iteration
		} else {
			// First turn for this session — create the thread record.
			m.mu.RLock()
			model := m.model
			m.mu.RUnlock()
			if createErr := store.CreateThread(ctx, sessionKey, model, nil); createErr != nil {
				slog.Error("agent: CreateThread failed (continuing statelessly)", logattr.SessionKey(sessionKey), logattr.Err(createErr))
				stateless = true
			}
		}
	}
	return messages, iteration, stateless, nil
}

// summarizationPrompt is the shared system prompt for all context compaction operations.
// Used by both threshold-based (runSummarization) and token-budget-triggered (buildCompactionSummary) paths.
const (
	summarizationPrompt = `You are a context summarization assistant. Condense the provided
conversation history into a concise summary. Preserve:
1. Key decisions made and agreed upon.
2. Active action items and their status.
3. User preferences and stylistic mandates.
4. Current task state and progress.

Format as a clear, bulleted list. If an existing <context_summary> block is provided,
integrate it hierarchically (do not discard prior summaries).

Conversation history:
`

	// DefaultMaxContextMessages is the message count above which compaction triggers.
	DefaultMaxContextMessages = 50
	// DefaultKeepContextMessages is the number of recent messages to retain after compaction.
	DefaultKeepContextMessages = 20

	statelessWarning = "⚠️ Warning: session history could not be initialized. This conversation will not be persisted.\n\n"
)

// dispatch is the implementation of Dispatch, potentially wrapped by tracing.
// store is the resolved per-user (or shared) CheckpointStore for this session.
func (m *SessionManager) dispatch(ctx context.Context, sessionKey, userID, userMessage string, messages []agentctx.StrategicMessage, iteration int, stateless bool, store CheckpointStore) (string, error) {
	cleaned, _ := StripSilent(userMessage)

	// 1. Prepare history (hooks, pruning, compaction)
	messages = m.prepareHistory(ctx, sessionKey, messages)

	// 2. Append incoming user message
	messages = append(messages, agentctx.StrategicMessage{
		Role:      agentctx.RoleUser,
		Content:   &agentctx.MessageContent{Str: &cleaned},
		CreatedAt: time.Now().Format(time.RFC3339),
	})

	// 3. Execute the turn
	response, updated, err := m.runner.Run(ctx, sessionKey, userID, messages)
	if err != nil {
		return "", fmt.Errorf("runner.Run: %w", err)
	}

	m.addMissingTimestamps(updated)

	// 4. Update budget and persist
	m.updateTokenBudget(ctx, sessionKey, updated, store)
	m.persistResult(ctx, sessionKey, iteration, updated, stateless, store)

	// 5. Post-dispatch hooks
	if m.hooks != nil {
		response = m.hooks.RunPostDispatch(ctx, sessionKey, response)
	}

	if stateless {
		response = statelessWarning + response
	}

	return response, nil
}

func (m *SessionManager) prepareHistory(ctx context.Context, sessionKey string, messages []agentctx.StrategicMessage) []agentctx.StrategicMessage {
	if m.hooks != nil {
		messages = m.runPreHistoryHooks(ctx, sessionKey, messages)
	}

	if pruned, droppedMsgs := PruneMessages(messages, m.pruningPolicy); len(droppedMsgs) > 0 {
		slog.Info("agent: pruned context", logattr.SessionKey(sessionKey), slog.Int("dropped", len(droppedMsgs)), slog.Int("remaining", len(pruned)))
		messages = pruned
		if m.consolidator != nil {
			m.consolidateDropped(sessionKey, droppedMsgs)
		}
	}

	messages = m.summarizeHistoryIfNeeded(ctx, sessionKey, messages)
	messages = m.compactHistoryIfNeeded(sessionKey, messages)

	return messages
}

func (m *SessionManager) runPreHistoryHooks(ctx context.Context, sessionKey string, messages []agentctx.StrategicMessage) []agentctx.StrategicMessage {
	original := messages
	messages = m.hooks.RunPreHistory(ctx, messages)
	if len(messages) == 0 && len(original) > 0 {
		if m.hooks.HasPreHistory() {
			slog.Warn("agent: RunPreHistory hook returned empty — preserving history as fallback", logattr.SessionKey(sessionKey))
		}
		return original
	}
	return messages
}

func (m *SessionManager) summarizeHistoryIfNeeded(ctx context.Context, sessionKey string, messages []agentctx.StrategicMessage) []agentctx.StrategicMessage {
	summarization := m.compactionPolicy.Summarization
	if !summarization.IsSummarizationEnabled() || len(messages) <= int(float64(m.memoryWindow)*summarization.SummarizationThreshold()) {
		return messages
	}

	model := summarization.SummarizationModel(m.model)
	if model == "" {
		slog.Warn("agent: summarization enabled but no model configured, skipping summarization", logattr.SessionKey(sessionKey))
		return messages
	}

	keepN := m.getSummarizationKeepN()
	if len(messages) <= keepN {
		return messages
	}

	toSummarize := messages[:len(messages)-keepN]
	summary, err := m.runSummarization(ctx, sessionKey, toSummarize, model)
	if err != nil {
		slog.Warn("agent: summarization failed, falling back to plain compaction", logattr.SessionKey(sessionKey), logattr.Err(err))
		return messages
	}

	slog.Info("agent: context summarized", logattr.SessionKey(sessionKey), slog.Int("summary_len", len(summary)))
	summaryMsg := agentctx.StrategicMessage{
		Role:      agentctx.RoleSystem,
		Content:   &agentctx.MessageContent{Str: &summary},
		CreatedAt: time.Now().Format(time.RFC3339),
	}

	newMsgs := []agentctx.StrategicMessage{summaryMsg} //nolint:prealloc // capacity is a complex expression involving keepN
	return append(newMsgs, messages[len(messages)-keepN:]...)
}

func (m *SessionManager) getSummarizationKeepN() int {
	keepN := DefaultKeepContextMessages
	if m.memoryWindow < keepN*2 {
		keepN = m.memoryWindow / 2
		if keepN < 1 {
			keepN = 1
		}
	}
	return keepN
}

func (m *SessionManager) runSummarization(ctx context.Context, sessionKey string, messages []agentctx.StrategicMessage, model string) (string, error) {
	var sb strings.Builder
	sb.WriteString(summarizationPrompt)
	for _, msg := range messages {
		if sb.Len() >= DefaultMaxCompactionInputBytes {
			slog.Warn("agent: summarization input exceeded byte cap, truncating", logattr.SessionKey(sessionKey))
			break
		}
		fmt.Fprintf(&sb, "%s: %s\n", msg.Role, msg.Content.String())
	}
	result, err := m.runner.RunText(ctx, sessionKey, sb.String(), model)
	if err != nil {
		return "", fmt.Errorf("run text: %w", err)
	}
	return result, nil
}

func (m *SessionManager) compactHistoryIfNeeded(sessionKey string, messages []agentctx.StrategicMessage) []agentctx.StrategicMessage {
	compacted, dropped, keep := CompactMessages(messages, m.memoryWindow, DefaultKeepContextMessages, m.compactionPolicy, m.pruningPolicy)
	if dropped <= 0 {
		return messages
	}

	slog.Info("agent: compacted context", logattr.SessionKey(sessionKey), slog.Int("dropped", dropped), slog.Int("remaining", len(compacted)))

	if m.consolidator != nil && m.compactionPolicy.Strategy == "memoryFlush" {
		m.runConsolidation(sessionKey, messages, keep)
	}

	if m.storageRoot != "" {
		entry := fmt.Sprintf("Session %s: compacted %d messages (kept %d)", sessionKey, dropped, len(compacted))
		memory.WriteJournalEntry(m.storageRoot, entry)
	}

	return compacted
}

func (m *SessionManager) runConsolidation(sessionKey string, messages []agentctx.StrategicMessage, keep []bool) {
	var sb strings.Builder
	for i, k := range keep {
		if !k && i < len(messages) {
			content := messages[i].Content.String()
			if memory.IsTrivialMessageForConsolidation(content) {
				continue
			}
			fmt.Fprintf(&sb, "%s: %s\n", messages[i].Role, content)
		}
	}
	droppedContent := strings.TrimSpace(sb.String())
	if droppedContent != "" {
		m.consolidator.ConsolidateAsync(sessionKey, droppedContent)
	}
}

func (m *SessionManager) consolidateDropped(sessionKey string, dropped []agentctx.StrategicMessage) {
	var sb strings.Builder
	for _, msg := range dropped {
		content := msg.Content.String()
		if memory.IsTrivialMessageForConsolidation(content) {
			continue
		}
		fmt.Fprintf(&sb, "%s: %s\n", msg.Role, content)
	}
	droppedContent := strings.TrimSpace(sb.String())
	if droppedContent != "" {
		m.consolidator.ConsolidateAsync(sessionKey, droppedContent)
	}
}

func (m *SessionManager) addMissingTimestamps(updated []agentctx.StrategicMessage) {
	for i := len(updated) - 1; i >= 0; i-- {
		if updated[i].CreatedAt == "" {
			updated[i].CreatedAt = time.Now().Format(time.RFC3339)
		} else {
			break
		}
	}
}

func (m *SessionManager) updateTokenBudget(ctx context.Context, sessionKey string, updated []agentctx.StrategicMessage, store CheckpointStore) {
	if m.tokenBudget <= 0 || store == nil {
		return
	}

	tokens, _, _ := store.GetSessionTokens(ctx, sessionKey)
	newTokens := tokens + estimateTokensForMessages(updated)
	if err := store.UpdateSessionTokens(ctx, sessionKey, newTokens, nil); err != nil {
		slog.Warn("agent: UpdateSessionTokens failed", logattr.SessionKey(sessionKey), logattr.Err(err))
	}
	slog.Debug("agent: session token budget", logattr.SessionKey(sessionKey), slog.Int("tokens", newTokens), slog.Int("budget", m.tokenBudget))
	if newTokens > m.tokenBudget {
		slog.Info("agent: session token budget exceeded, triggering compaction", logattr.SessionKey(sessionKey))
		go m.compactSessionAsync(ctx, sessionKey, store)
	}
}

func (m *SessionManager) persistResult(ctx context.Context, sessionKey string, iteration int, updated []agentctx.StrategicMessage, stateless bool, store CheckpointStore) {
	if stateless || store == nil || len(updated) == 0 {
		return
	}

	it := iteration + 1
	if _, err := store.SaveSnapshot(ctx, sessionKey, it, updated); err != nil {
		slog.Warn("agent: SaveSnapshot failed", logattr.SessionKey(sessionKey), logattr.Err(err))
	}

	if m.logger != nil {
		if err := m.logger.Log(sessionKey, it, updated); err != nil {
			slog.Warn("agent: session log write failed", logattr.SessionKey(sessionKey), logattr.Err(err))
		}
	}
}

// estimateTokensForMessages estimates the total token count for a message slice.
// Uses a simple word-based heuristic: ~1.3 tokens per word, with per-message overhead.
// This avoids adding a tokenizer dependency.
func estimateTokensForMessages(messages []agentctx.StrategicMessage) int {
	// avgTokensPerWord is the estimated number of LLM tokens per English word (~1.3).
	// Derivation: 1 / 0.77 ≈ 1.3 tokens/word (based on GPT-family tokenizer data).
	const avgTokensPerWord = 1.3
	const overheadPerMsg = 4
	total := 0
	for _, msg := range messages {
		content := ""
		if msg.Content != nil {
			content = msg.Content.String()
		}
		words := len(strings.Fields(content))
		total += int(float64(words)*avgTokensPerWord) + overheadPerMsg
	}
	return total
}

// compactSessionAsync loads the session history, compacts the oldest N turns by
// summarizing them into a single system message, and persists the result.
// store is the resolved per-user (or shared) CheckpointStore for this session.
// Errors are logged but not returned since compaction runs in a background goroutine.
func (m *SessionManager) buildCompactionSummary(ctx context.Context, sessionKey string, toSummarize []agentctx.StrategicMessage) (string, error) {
	model := m.compactionPolicy.Summarization.SummarizationModel(m.model)
	var sb strings.Builder
	for _, msg := range toSummarize {
		fmt.Fprintf(&sb, "%s: %s\n", msg.Role, msg.Content.String())
	}
	inputText := sb.String()
	// Use WithoutCancel to ensure background compaction continues even if
	// the triggering request is cancelled.
	bgCtx := context.WithoutCancel(ctx)
	result, err := m.runner.RunText(bgCtx, sessionKey, summarizationPrompt+inputText, model)
	if err != nil {
		return "", fmt.Errorf("summarize: %w", err)
	}
	return result, nil
}

func (m *SessionManager) compactSessionAsync(ctx context.Context, sessionKey string, store CheckpointStore) {
	slog.Info("agent: starting per-session compaction", logattr.SessionKey(sessionKey))
	snap, err := store.LoadLatest(ctx, sessionKey)
	if err != nil {
		slog.Warn("agent: compactSessionAsync LoadLatest failed", logattr.SessionKey(sessionKey), logattr.Err(err))
		return
	}
	if snap == nil || len(snap.Messages) == 0 {
		slog.Warn("agent: compactSessionAsync no messages to compact", logattr.SessionKey(sessionKey))
		return
	}
	summaryTurns := m.summaryTurns
	if summaryTurns <= 0 {
		summaryTurns = 20
	}
	if len(snap.Messages) <= summaryTurns {
		slog.Info("agent: compactSessionAsync not enough messages to compact", logattr.SessionKey(sessionKey), slog.Int("have", len(snap.Messages)), slog.Int("need", summaryTurns+1))
		return
	}
	toSummarize := snap.Messages[:len(snap.Messages)-summaryTurns]
	kept := snap.Messages[len(snap.Messages)-summaryTurns:]
	summary, err := m.buildCompactionSummary(ctx, sessionKey, toSummarize)
	if err != nil {
		slog.Warn("agent: compactSessionAsync summarization failed", logattr.SessionKey(sessionKey), logattr.Err(err))
		return
	}
	summaryMsg := agentctx.StrategicMessage{
		Role:      agentctx.RoleSystem,
		Content:   &agentctx.MessageContent{Str: &summary},
		CreatedAt: time.Now().Format(time.RFC3339),
	}
	compacted := append([]agentctx.StrategicMessage{summaryMsg}, kept...)
	now := time.Now()
	tokens := estimateTokensForMessages(compacted)
	if err := store.UpdateSessionTokens(ctx, sessionKey, tokens, &now); err != nil {
		slog.Warn("agent: UpdateSessionTokens after compaction failed", logattr.SessionKey(sessionKey), logattr.Err(err))
	}
	_, err = store.SaveSnapshot(ctx, sessionKey, snap.Iteration, compacted)
	if err != nil {
		slog.Warn("agent: SaveSnapshot after compaction failed", logattr.SessionKey(sessionKey), logattr.Err(err))
		return
	}
	slog.Info("agent: per-session compaction complete", logattr.SessionKey(sessionKey), slog.Int("before", len(snap.Messages)), slog.Int("after", len(compacted)), slog.Int("tokens_after", tokens))
}
