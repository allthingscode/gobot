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
	"github.com/allthingscode/gobot/internal/logattr"
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

// GetRunner returns the underlying Runner used by this SessionManager.
func (m *SessionManager) GetRunner() Runner {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.runner
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
			slog.Warn("agent: CheckpointStoreProvider failed, falling back to shared store", logattr.UserID(userID), logattr.Err(err))
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
