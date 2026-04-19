// Package agent manages per-session serialization of agentic turns.
//
// It is the Go equivalent of AgentLoopPatch in patches/loop.py:
//   - Per-session locks prevent concurrent tool/state races within a session
//     (mirrors WeakValueDictionary of asyncio.Lock in _patched_dispatch).
//   - Checkpoint load/save surrounds every turn (mirrors _patched_run_agent_loop).
//   - [SILENT] prefix stripping keeps the prompt clean for the AI model.
//
// The Runner interface is intentionally narrow so that tests can use a mock
// and production can plug in an ADK-backed implementation without coupling
// this package to google.golang.org/adk.
package agent

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"time"

	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/memory"
	"github.com/allthingscode/gobot/internal/observability"
)

// ErrToolDenied is returned by pre-tool hooks when a tool execution is denied
// by policy or HITL. This is a Category B failure that aborts the tool loop.
var ErrToolDenied = errors.New("tool execution denied")

// ErrUnknownTool is returned when an agent attempts to call a tool that
// has not been registered with the runner. Category B.
var ErrUnknownTool = errors.New("unknown tool")

// Runner executes one agentic turn.
// It receives the full conversation history and returns the model's response
// text plus the updated history (with the new assistant turn appended).
//
// Implementations must be safe for concurrent use across different sessionKeys;
// SessionManager ensures calls with the same key are serialized.
type Runner interface {
	// Run executes a full turn of the agent, including tool calls and history updates.
	// userID is used for workspace and memory isolation (F-073).
	Run(ctx context.Context, sessionKey, userID string, messages []agentctx.StrategicMessage) (response string, updated []agentctx.StrategicMessage, err error)
	// RunText executes a single-turn completion (text-only) with no tool use.
	RunText(ctx context.Context, sessionKey, prompt string, modelOverride string) (string, error)
}

// CheckpointStore abstracts the checkpoint persistence layer.
// Pass nil to SessionManager to run statelessly (no history loaded or saved).
type CheckpointStore interface {
	// LoadLatest retrieves the most recent thread snapshot for the given threadID.
	LoadLatest(ctx context.Context, threadID string) (*agentctx.ThreadSnapshot, error)
	// SaveSnapshot persists a conversation snapshot for a specific iteration.
	SaveSnapshot(ctx context.Context, threadID string, iteration int, messages []agentctx.StrategicMessage) (bool, error)
	// CreateThread initializes a new durable thread record.
	CreateThread(ctx context.Context, threadID, model string, metadata map[string]any) error
	// UpdateSessionTokens updates the estimated_tokens and last_compacted_at for a thread.
	UpdateSessionTokens(ctx context.Context, threadID string, tokens int, compactedAt *time.Time) error
	// GetSessionTokens reads estimated_tokens and last_compacted_at for a thread.
	GetSessionTokens(ctx context.Context, threadID string) (tokens int, compactedAt *time.Time, err error)
}

// Consolidator abstracts the memory consolidation/fact extraction layer (F-028, F-047).
type Consolidator interface {
	// ConsolidateAsync extracts facts from text in a background goroutine.
	ConsolidateAsync(sessionKey, text string)
}

// SessionManager serializes Runner calls per session key and optionally
// persists conversation history via a CheckpointStore.
//
// Concurrent calls with the same sessionKey are queued; concurrent calls
// with different sessionKeys proceed in parallel.
type SessionManager struct {
	mu                      sync.RWMutex
	runner                  Runner
	store                   CheckpointStore                              // may be nil; shared single-user store
	checkpointStoreProvider func(userID string) (CheckpointStore, error) // may be nil; F-105 per-user
	model                   string
	storageRoot             string        // may be ""; used for journal writes on compaction
	logger                  SessionLogger // may be nil; set via SetLogger
	consolidator            Consolidator  // may be nil; set via SetConsolidator
	hooks                   *Hooks        // may be nil; set via SetHooks
	tracer                  *observability.DispatchTracer
	memoryWindow            int
	lockTimeout             time.Duration
	pruningPolicy           config.ContextPruningConfig
	compactionPolicy        config.CompactionPolicyConfig
	tokenBudget             int // per-session token budget before triggering compaction (F-104)
	summaryTurns            int // how many oldest turns to summarize per compaction pass (F-104)
}

// NewSessionManager creates a SessionManager backed by runner.
// store may be nil for stateless operation.
// model is recorded when creating new checkpoint threads (e.g. "gemini-2.5-flash").
func NewSessionManager(runner Runner, store CheckpointStore, model string) *SessionManager {
	return &SessionManager{
		runner:       runner,
		store:        store,
		model:        model,
		memoryWindow: DefaultMaxContextMessages,
		lockTimeout:  120 * time.Second,
	}
}

// SetTracer configures the observability tracer for the session manager.
func (m *SessionManager) SetTracer(t *observability.DispatchTracer) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.tracer = t
}

// SetLockTimeout configures the maximum time to wait for a session lock.
func (m *SessionManager) SetLockTimeout(d time.Duration) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if d > 0 {
		m.lockTimeout = d
	}
}

// SetMemoryWindow configures the maximum context messages kept before compaction.
func (m *SessionManager) SetMemoryWindow(w int) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if w > 0 {
		m.memoryWindow = w
	}
}

// SetPruningPolicy configures the context pruning policy.
func (m *SessionManager) SetPruningPolicy(p config.ContextPruningConfig) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.pruningPolicy = p
}

// SetCompactionPolicy configures the context compaction policy.
func (m *SessionManager) SetCompactionPolicy(p config.CompactionPolicyConfig) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.compactionPolicy = p
}

// SetStorageRoot configures the storage root used for journal writes on
// context compaction. Call this after NewSessionManager when journaling is
// desired. An empty root disables journal writes.
func (m *SessionManager) SetStorageRoot(root string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.storageRoot = root
}

// SetLogger configures a SessionLogger that receives a copy of the conversation
// after every successful SaveSnapshot. If nil, no logging is performed.
func (m *SessionManager) SetLogger(l SessionLogger) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.logger = l
}

// SetConsolidator configures a Consolidator that extracts facts from dropped
// history during memoryFlush compaction. If nil, no consolidation is performed.
func (m *SessionManager) SetConsolidator(c Consolidator) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.consolidator = c
}

// SetHooks configures the lifecycle hooks for this SessionManager.
// Call this at startup before the first Dispatch. Hooks run in registration order.
func (m *SessionManager) SetHooks(h *Hooks) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.hooks = h
}

// SetTokenBudget configures the per-session token budget (F-104).
func (m *SessionManager) SetTokenBudget(budget int) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if budget > 0 {
		m.tokenBudget = budget
	}
}

// SetSummaryTurns configures how many turns to summarize per compaction (F-104).
func (m *SessionManager) SetSummaryTurns(turns int) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if turns > 0 {
		m.summaryTurns = turns
	}
}

// SetCheckpointStoreProvider configures a factory that returns a per-user
// CheckpointStore when multi-user workspace isolation is enabled (F-105).
// When set and userID is non-empty, Dispatch will call this factory to obtain
// the store rather than using the shared m.store.
func (m *SessionManager) SetCheckpointStoreProvider(fn func(userID string) (CheckpointStore, error)) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.checkpointStoreProvider = fn
}

// resolveStore returns the CheckpointStore to use for the given userID.
// If a checkpointStoreProvider is configured and userID is non-empty it is
// called; otherwise the shared m.store is returned.
func (m *SessionManager) resolveStore(userID string) CheckpointStore {
	m.mu.RLock()
	provider := m.checkpointStoreProvider
	sharedStore := m.store
	m.mu.RUnlock()

	if provider != nil && userID != "" {
		if s, err := provider(userID); err == nil {
			return s
		} else {
			slog.Warn("agent: CheckpointStoreProvider failed, falling back to shared store", "userID", userID, "err", err)
		}
	}
	return sharedStore
}

// Dispatch delivers userMessage to the runner under a per-session lock.
//
// If a CheckpointStore is configured:
//   - Loads conversation history for sessionKey before calling the runner.
//   - Saves the updated history returned by the runner.
//
// The [SILENT] prefix is stripped from userMessage before it reaches the runner.
// Returns the runner's response, or an error if the runner or store fails.
func (m *SessionManager) Dispatch(ctx context.Context, sessionKey, userID, userMessage string) (string, error) {
	m.mu.RLock()
	lockTimeout := m.lockTimeout
	tracer := m.tracer
	m.mu.RUnlock()

	lock := acquireLock(sessionKey, lockTimeout)
	if err := lock.Lock(ctx); err != nil {
		lock.release()
		return "", err
	}
	defer func() {
		lock.Unlock()
		lock.release()
	}()

	// F-105: resolve per-user store when multi-user isolation is enabled.
	store := m.resolveStore(userID)

	if tracer != nil {
		// Load history first so we can report message count to tracer.
		messages, iteration, stateless, err := m.loadHistory(ctx, sessionKey, store)
		if err != nil {
			return "", err
		}
		resp, err := tracer.TraceAgentDispatch(ctx, sessionKey, len(messages), func(ctx context.Context) (string, error) {
			return m.dispatch(ctx, sessionKey, userID, userMessage, messages, iteration, stateless, store)
		})
		if err != nil {
			return "", fmt.Errorf("trace dispatch: %w", err)
		}
		return resp, nil
	}

	messages, iteration, stateless, err := m.loadHistory(ctx, sessionKey, store)
	if err != nil {
		return "", err
	}
	return m.dispatch(ctx, sessionKey, userID, userMessage, messages, iteration, stateless, store)
}

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
				slog.Error("agent: CreateThread failed (continuing statelessly)", "session", sessionKey, "err", createErr)
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
		slog.Info("agent: pruned context", "session", sessionKey, "dropped", len(droppedMsgs), "remaining", len(pruned))
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
			slog.Warn("agent: RunPreHistory hook returned empty — preserving history as fallback", "session", sessionKey)
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
		slog.Warn("agent: summarization enabled but no model configured, skipping summarization", "session", sessionKey)
		return messages
	}

	keepN := m.getSummarizationKeepN()
	if len(messages) <= keepN {
		return messages
	}

	toSummarize := messages[:len(messages)-keepN]
	summary, err := m.runSummarization(ctx, sessionKey, toSummarize, model)
	if err != nil {
		slog.Warn("agent: summarization failed, falling back to plain compaction", "session", sessionKey, "err", err)
		return messages
	}

	slog.Info("agent: context summarized", "session", sessionKey, "summary_len", len(summary))
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
			slog.Warn("agent: summarization input exceeded byte cap, truncating", "session", sessionKey)
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

	slog.Info("agent: compacted context", "session", sessionKey, "dropped", dropped, "remaining", len(compacted))

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
		slog.Warn("agent: UpdateSessionTokens failed", "session", sessionKey, "err", err)
	} else {
		slog.Debug("agent: session token budget", "session", sessionKey, "tokens", newTokens, "budget", m.tokenBudget)
		if newTokens > m.tokenBudget && m.summaryTurns > 0 {
			slog.Info("agent: session token budget exceeded, triggering compaction", "session", sessionKey)
			go m.compactSessionAsync(ctx, sessionKey, store)
		}
	}
}

func (m *SessionManager) persistResult(ctx context.Context, sessionKey string, iteration int, updated []agentctx.StrategicMessage, stateless bool, store CheckpointStore) {
	if stateless || store == nil || len(updated) == 0 {
		return
	}

	it := iteration + 1
	if _, err := store.SaveSnapshot(ctx, sessionKey, it, updated); err != nil {
		slog.Warn("agent: SaveSnapshot failed", "session", sessionKey, "err", err)
	}

	if m.logger != nil {
		if err := m.logger.Log(sessionKey, it, updated); err != nil {
			slog.Warn("agent: session log write failed", "session", sessionKey, "err", err)
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
	slog.Info("agent: starting per-session compaction", "session", sessionKey)
	snap, err := store.LoadLatest(ctx, sessionKey)
	if err != nil {
		slog.Warn("agent: compactSessionAsync LoadLatest failed", "session", sessionKey, "err", err)
		return
	}
	if snap == nil || len(snap.Messages) == 0 {
		slog.Warn("agent: compactSessionAsync no messages to compact", "session", sessionKey)
		return
	}
	summaryTurns := m.summaryTurns
	if summaryTurns <= 0 {
		summaryTurns = 20
	}
	if len(snap.Messages) <= summaryTurns {
		slog.Info("agent: compactSessionAsync not enough messages to compact", "session", sessionKey, "have", len(snap.Messages), "need", summaryTurns+1)
		return
	}
	toSummarize := snap.Messages[:len(snap.Messages)-summaryTurns]
	kept := snap.Messages[len(snap.Messages)-summaryTurns:]
	summary, err := m.buildCompactionSummary(ctx, sessionKey, toSummarize)
	if err != nil {
		slog.Warn("agent: compactSessionAsync summarization failed", "session", sessionKey, "err", err)
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
		slog.Warn("agent: UpdateSessionTokens after compaction failed", "session", sessionKey, "err", err)
	}
	_, err = store.SaveSnapshot(ctx, sessionKey, snap.Iteration, compacted)
	if err != nil {
		slog.Warn("agent: SaveSnapshot after compaction failed", "session", sessionKey, "err", err)
		return
	}
	slog.Info("agent: per-session compaction complete", "session", sessionKey, "before", len(snap.Messages), "after", len(compacted), "tokens_after", tokens)
}

// StripSilent removes the "[SILENT]" prefix from message (trimming surrounding
// whitespace) and reports whether the prefix was present.
//
// Mirrors the [SILENT] handling in _patched_dispatch (loop.py) and
// resolve_routable_channel (cron_logic.py).
func StripSilent(message string) (cleaned string, silent bool) {
	if trimmed, ok := strings.CutPrefix(message, "[SILENT]"); ok {
		return strings.TrimSpace(trimmed), true
	}
	return message, false
}
