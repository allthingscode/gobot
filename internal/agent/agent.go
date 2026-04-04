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
	"time"

	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/memory"
	"github.com/allthingscode/gobot/internal/observability"
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

// Consolidator abstracts the memory consolidation/fact extraction layer (F-028, F-047).
type Consolidator interface {
	ConsolidateAsync(sessionKey, text string)
}

// SessionManager serializes Runner calls per session key and optionally
// persists conversation history via a CheckpointStore.
//
// Concurrent calls with the same sessionKey are queued; concurrent calls
// with different sessionKeys proceed in parallel.
type SessionManager struct {
	runner           Runner
	store            CheckpointStore // may be nil
	model            string
	storageRoot      string        // may be ""; used for journal writes on compaction
	logger           SessionLogger // may be nil; set via SetLogger
	consolidator     Consolidator  // may be nil; set via SetConsolidator
	hooks            *Hooks        // may be nil; set via SetHooks
	tracer           *observability.DispatchTracer
	memoryWindow     int
	pruningPolicy    config.ContextPruningConfig
	compactionPolicy config.CompactionPolicyConfig
	mu               sync.Map // key: sessionKey (string) → *sessionLock
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
	}
}

// SetTracer configures the observability tracer for the session manager.
func (m *SessionManager) SetTracer(t *observability.DispatchTracer) {
	m.tracer = t
}

// SetMemoryWindow configures the maximum context messages kept before compaction.
func (m *SessionManager) SetMemoryWindow(w int) {
	if w > 0 {
		m.memoryWindow = w
	}
}

// SetPruningPolicy configures the context pruning policy.
func (m *SessionManager) SetPruningPolicy(p config.ContextPruningConfig) {
	m.pruningPolicy = p
}

// SetCompactionPolicy configures the context compaction policy.
func (m *SessionManager) SetCompactionPolicy(p config.CompactionPolicyConfig) {
	m.compactionPolicy = p
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

// SetConsolidator configures a Consolidator that extracts facts from dropped
// history during memoryFlush compaction. If nil, no consolidation is performed.
func (m *SessionManager) SetConsolidator(c Consolidator) {
	m.consolidator = c
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

	if m.tracer != nil {
		// Load history first so we can report message count to tracer.
		messages, iteration, err := m.loadHistory(sessionKey)
		if err != nil {
			return "", err
		}
		return m.tracer.TraceAgentDispatch(ctx, sessionKey, len(messages), func(ctx context.Context) (string, error) {
			return m.dispatch(ctx, sessionKey, userMessage, messages, iteration)
		})
	}

	messages, iteration, err := m.loadHistory(sessionKey)
	if err != nil {
		return "", err
	}
	return m.dispatch(ctx, sessionKey, userMessage, messages, iteration)
}

// loadHistory loads conversation history from checkpoint.
func (m *SessionManager) loadHistory(sessionKey string) ([]agentctx.StrategicMessage, int, error) {
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
	return messages, iteration, nil
}

// dispatch is the implementation of Dispatch, potentially wrapped by tracing.
func (m *SessionManager) dispatch(ctx context.Context, sessionKey, userMessage string, messages []agentctx.StrategicMessage, iteration int) (string, error) {
	// Strip [SILENT] prefix — the cron layer uses it to suppress routing
	// but the model should never see it (mirrors _patched_dispatch in loop.py).
	cleaned, silent := StripSilent(userMessage)
	if silent {
		slog.Debug("agent: [SILENT] message received, stripping prefix", "session", sessionKey)
	}

	// Run PreHistory hooks (F-012) — filter/transform history before compaction and dispatch.
	if m.hooks != nil {
		messages = m.hooks.RunPreHistory(ctx, messages)
	}

	// Prune context based on TTL and KeepLastAssistants (F-047).
	if pruned, dropped := PruneMessages(messages, m.pruningPolicy); dropped > 0 {
		slog.Info("agent: pruned context", "session", sessionKey, "dropped", dropped, "remaining", len(pruned))
		messages = pruned
	}

	// Compact context if the history has grown too large (F-015, F-047).
	if compacted, dropped, keep := CompactMessages(messages, m.memoryWindow, DefaultKeepContextMessages, m.compactionPolicy, m.pruningPolicy); dropped > 0 {
		slog.Info("agent: compacted context", "session", sessionKey, "dropped", dropped, "remaining", len(compacted))
		if m.consolidator != nil && m.compactionPolicy.Strategy == "memoryFlush" {
			// Extract facts from dropped history (F-047, F-068).
			// Use the keep[] array to identify which messages were actually dropped.
			// Filter out trivial messages (ok, yes, etc.) before consolidation.
			var sb strings.Builder
			for i, k := range keep {
				if !k && i < len(messages) {
					msg := messages[i]
					content := msg.Content.String()
					// Skip trivial messages that don't warrant fact extraction (F-068)
					if memory.IsTrivialMessageForConsolidation(content) {
						continue
					}
					fmt.Fprintf(&sb, "%s: %s\n", msg.Role, content)
				}
			}
			// Only call consolidator if there are meaningful messages
			droppedContent := strings.TrimSpace(sb.String())
			if droppedContent != "" {
				m.consolidator.ConsolidateAsync(sessionKey, droppedContent)
			}
		}
		if m.storageRoot != "" {
			entry := fmt.Sprintf("Session %s: compacted %d messages (kept %d)", sessionKey, dropped, len(compacted))
			memory.WriteJournalEntry(m.storageRoot, entry)
		}
		messages = compacted
	}

	// Append the incoming user message.
	messages = append(messages, agentctx.StrategicMessage{
		Role:      "user",
		Content:   &agentctx.MessageContent{Str: &cleaned},
		CreatedAt: time.Now().Format(time.RFC3339),
	})

	// Execute the turn.
	response, updated, err := m.runner.Run(ctx, sessionKey, messages)
	if err != nil {
		return "", fmt.Errorf("runner.Run: %w", err)
	}

	// Ensure the model's response also has a timestamp if it doesn't already.
	// We scan the 'updated' history (which should have the last assistant turn).
	for i := len(updated) - 1; i >= 0; i-- {
		if updated[i].CreatedAt == "" {
			updated[i].CreatedAt = time.Now().Format(time.RFC3339)
		} else {
			// Once we find one with a timestamp, we assume older ones are fine.
			break
		}
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

	// Run PostDispatch hooks (F-063: Automated Handoffs).
	if m.hooks != nil {
		response = m.hooks.RunPostDispatch(ctx, sessionKey, response)
	}

	return response, nil
}

// lockFor returns the existing session lock for sessionKey, creating one if needed.
// Uses LoadOrStore for goroutine-safe lazy initialisation.
func (m *SessionManager) lockFor(sessionKey string) *sessionLock {
	if val, ok := m.mu.Load(sessionKey); ok {
		return val.(*sessionLock)
	}
	val, _ := m.mu.LoadOrStore(sessionKey, newSessionLock(sessionKey))
	return val.(*sessionLock)
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
