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
	"fmt"
	"log/slog"
	"strings"
	"sync"

	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/memory"
)

// Runner executes one agentic turn.
// It receives the full conversation history and returns the model's response
// text plus the updated history (with the new assistant turn appended).
//
// Implementations must be safe for concurrent use across different sessionKeys;
// SessionManager ensures calls with the same key are serialized.
type Runner interface {
	Run(ctx context.Context, sessionKey string, messages []agentctx.StrategicMessage) (response string, updated []agentctx.StrategicMessage, err error)
}

// CheckpointStore abstracts the checkpoint persistence layer.
// Pass nil to SessionManager to run statelessly (no history loaded or saved).
type CheckpointStore interface {
	LoadLatest(threadID string) (*agentctx.ThreadSnapshot, error)
	SaveSnapshot(threadID string, iteration int, messages []agentctx.StrategicMessage) (bool, error)
	CreateThread(threadID, model string, metadata map[string]any) error
}

// SessionManager serializes Runner calls per session key and optionally
// persists conversation history via a CheckpointStore.
//
// Concurrent calls with the same sessionKey are queued; concurrent calls
// with different sessionKeys proceed in parallel.
type SessionManager struct {
	runner      Runner
	store       CheckpointStore // may be nil
	model       string
	storageRoot string    // may be ""; used for journal writes on compaction
	logger      SessionLogger // may be nil; set via SetLogger
	hooks       *Hooks    // may be nil; set via SetHooks
	mu          sync.Map  // key: sessionKey (string) → *sync.Mutex
}

// NewSessionManager creates a SessionManager backed by runner.
// store may be nil for stateless operation.
// model is recorded when creating new checkpoint threads (e.g. "gemini-2.5-flash").
func NewSessionManager(runner Runner, store CheckpointStore, model string) *SessionManager {
	return &SessionManager{
		runner: runner,
		store:  store,
		model:  model,
	}
}

// SetStorageRoot configures the storage root used for journal writes on
// context compaction. Call this after NewSessionManager when journaling is
// desired. An empty root disables journal writes.
func (m *SessionManager) SetStorageRoot(root string) {
	m.storageRoot = root
}

// SetLogger configures a SessionLogger that receives a copy of the conversation
// after every successful SaveSnapshot. If nil, no logging is performed.
func (m *SessionManager) SetLogger(l SessionLogger) {
	m.logger = l
}

// SetHooks configures the lifecycle hooks for this SessionManager.
// Call this at startup before the first Dispatch. Hooks run in registration order.
func (m *SessionManager) SetHooks(h *Hooks) {
	m.hooks = h
}

// Dispatch delivers userMessage to the runner under a per-session lock.
//
// If a CheckpointStore is configured:
//   - Loads conversation history for sessionKey before calling the runner.
//   - Saves the updated history returned by the runner.
//
// The [SILENT] prefix is stripped from userMessage before it reaches the runner.
// Returns the runner's response, or an error if the runner or store fails.
func (m *SessionManager) Dispatch(ctx context.Context, sessionKey, userMessage string) (string, error) {
	lock := m.lockFor(sessionKey)
	lock.Lock()
	defer lock.Unlock()

	// Strip [SILENT] prefix — the cron layer uses it to suppress routing
	// but the model should never see it (mirrors _patched_dispatch in loop.py).
	cleaned, silent := StripSilent(userMessage)
	if silent {
		slog.Debug("agent: [SILENT] message received, stripping prefix", "session", sessionKey)
	}

	// Load conversation history from checkpoint.
	var messages []agentctx.StrategicMessage
	var iteration int
	if m.store != nil {
		snap, err := m.store.LoadLatest(sessionKey)
		if err == nil && snap != nil {
			messages = snap.Messages
			iteration = snap.Iteration
		} else {
			// First turn for this session — create the thread record.
			if createErr := m.store.CreateThread(sessionKey, m.model, nil); createErr != nil {
				slog.Warn("agent: CreateThread failed (continuing statelessly)", "session", sessionKey, "err", createErr)
			}
		}
	}

	// Run PreHistory hooks (F-012) — filter/transform history before compaction and dispatch.
	if m.hooks != nil {
		messages = m.hooks.RunPreHistory(ctx, messages)
	}

	// Compact context if the history has grown too large (F-015).
	if compacted, dropped := CompactMessages(messages, DefaultMaxContextMessages, DefaultKeepContextMessages); dropped > 0 {
		slog.Info("agent: compacted context", "session", sessionKey, "dropped", dropped, "remaining", len(compacted))
		if m.storageRoot != "" {
			entry := fmt.Sprintf("Session %s: compacted %d messages (kept %d)", sessionKey, dropped, len(compacted))
			memory.WriteJournalEntry(m.storageRoot, entry)
		}
		messages = compacted
	}

	// Append the incoming user message.
	messages = append(messages, agentctx.StrategicMessage{
		Role:    "user",
		Content: &agentctx.MessageContent{Str: &cleaned},
	})

	// Execute the turn.
	response, updated, err := m.runner.Run(ctx, sessionKey, messages)
	if err != nil {
		return "", fmt.Errorf("runner.Run: %w", err)
	}

	// Persist the updated history.
	if m.store != nil && len(updated) > 0 {
		iteration++
		if _, saveErr := m.store.SaveSnapshot(sessionKey, iteration, updated); saveErr != nil {
			slog.Warn("agent: SaveSnapshot failed", "session", sessionKey, "err", saveErr)
		}
		// Write markdown session log (F-037).
		if m.logger != nil {
			if logErr := m.logger.Log(sessionKey, iteration, updated); logErr != nil {
				slog.Warn("agent: session log write failed", "session", sessionKey, "err", logErr)
			}
		}
	}

	return response, nil
}

// lockFor returns the existing mutex for sessionKey, creating one if needed.
// Uses LoadOrStore for goroutine-safe lazy initialisation.
func (m *SessionManager) lockFor(sessionKey string) *sync.Mutex {
	val, _ := m.mu.LoadOrStore(sessionKey, &sync.Mutex{})
	return val.(*sync.Mutex)
}

// StripSilent removes the "[SILENT]" prefix from message (trimming surrounding
// whitespace) and reports whether the prefix was present.
//
// Mirrors the [SILENT] handling in _patched_dispatch (loop.py) and
// resolve_routable_channel (cron_logic.py).
func StripSilent(message string) (cleaned string, silent bool) {
	if strings.HasPrefix(message, "[SILENT]") {
		return strings.TrimSpace(strings.TrimPrefix(message, "[SILENT]")), true
	}
	return message, false
}
