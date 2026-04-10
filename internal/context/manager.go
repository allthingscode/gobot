package context

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"sync"
)

// ThreadSnapshot is the return type for LoadLatest.
type ThreadSnapshot struct {
	Iteration int                // The sequential iteration number of this snapshot.
	Messages  []StrategicMessage // The full message history up to this point.
	Model     string             // The model used when the thread was created.
	Metadata  map[string]any     // Arbitrary key-value metadata.
}

// ResumableThread is one entry in the ListResumable result.
type ResumableThread struct {
	ThreadID        string // Unique identifier for the thread.
	Model           string // Model associated with the thread.
	UpdatedAt       string // Timestamp of the last update (RFC3339).
	LatestIteration int    // The highest iteration number recorded for this thread.
}

// CheckpointManager manages SQLite-based durability for the Strategic Edition
// agent loop. It mirrors checkpoint_logic.py's CheckpointManager class.
// Obtain an instance via GetCheckpointManager — do not construct directly.
type CheckpointManager struct {
	db *sql.DB
}

var (
	cmInstance *CheckpointManager
	cmOnce     sync.Once
	cmInitErr  error
)

// GetCheckpointManager returns the process-wide singleton CheckpointManager,
// initialising it on the first call. Subsequent calls ignore storageRoot.
func GetCheckpointManager(storageRoot string) (*CheckpointManager, error) {
	cmOnce.Do(func() {
		db, err := openDB(storageRoot)
		if err != nil {
			cmInitErr = err
			return
		}
		if err := initSchema(db); err != nil {
			_ = db.Close()
			cmInitErr = err
			return
		}
		cmInstance = &CheckpointManager{db: db}
	})
	return cmInstance, cmInitErr
}

// CreateThread initialises a new durable thread, replacing any existing row
// with the same thread_id (mirrors Python's INSERT OR REPLACE).
func (m *CheckpointManager) CreateThread(threadID, model string, metadata map[string]any) error {
	if metadata == nil {
		metadata = map[string]any{}
	}
	metaJSON, err := json.Marshal(metadata)
	if err != nil {
		return fmt.Errorf("CreateThread: marshal metadata: %w", err)
	}
	_, err = m.db.Exec(
		`INSERT OR REPLACE INTO threads (thread_id, model, status, metadata, updated_at)
		 VALUES (?, ?, 'active', ?, CURRENT_TIMESTAMP)`,
		threadID, model, string(metaJSON),
	)
	if err != nil {
		return fmt.Errorf("CreateThread: exec: %w", err)
	}
	return nil
}

// SaveSnapshot atomically persists the agent state for a given iteration.
// Messages are validated by round-tripping through JSON before being stored.
// Returns false (and a nil error) if validation fails, matching Python's
// silent-false behaviour on validation error.
func (m *CheckpointManager) SaveSnapshot(threadID string, iteration int, messages []StrategicMessage) (bool, error) {
	stateJSON, err := json.Marshal(messages)
	if err != nil {
		var preview string
		if len(messages) > 0 && messages[0].Content != nil {
			preview = truncate(messages[0].Content.String(), 200)
		}
		slog.Warn("context: SaveSnapshot skipped — message failed validation (marshal)",
			"session", threadID,
			"reason", err,
			"preview", preview)
		return false, nil //nolint:nilerr // mirrors Python: log and return false
	}
	// Validate round-trip.
	var check []StrategicMessage
	if err := json.Unmarshal(stateJSON, &check); err != nil {
		slog.Warn("context: SaveSnapshot skipped — message failed validation (unmarshal)",
			"session", threadID,
			"reason", err,
			"preview", truncate(string(stateJSON), 200))
		return false, nil
	}

	sum := sha256.Sum256(stateJSON)
	checksum := hex.EncodeToString(sum[:])

	tx, err := m.db.Begin()
	if err != nil {
		return false, fmt.Errorf("SaveSnapshot: begin tx: %w", err)
	}
	defer tx.Rollback() //nolint:errcheck // Rollback is a no-op if tx is committed

	if _, err := tx.Exec(
		`INSERT INTO checkpoints (thread_id, iteration, state, checksum) VALUES (?, ?, ?, ?)`,
		threadID, iteration, string(stateJSON), checksum,
	); err != nil {
		return false, fmt.Errorf("SaveSnapshot: insert checkpoint: %w", err)
	}
	if _, err := tx.Exec(
		`UPDATE threads SET updated_at = CURRENT_TIMESTAMP WHERE thread_id = ?`,
		threadID,
	); err != nil {
		return false, fmt.Errorf("SaveSnapshot: update thread: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return false, fmt.Errorf("SaveSnapshot: commit: %w", err)
	}
	return true, nil
}

// LoadLatest returns the most recent snapshot for a thread, or nil if none exists.
func (m *CheckpointManager) LoadLatest(threadID string) (*ThreadSnapshot, error) {
	row := m.db.QueryRow(
		`SELECT iteration, state, checksum FROM checkpoints
		 WHERE thread_id = ?
		 ORDER BY iteration DESC, checkpoint_id DESC
		 LIMIT 1`,
		threadID,
	)

	var iteration int
	var stateJSON string
	var checksumNS sql.NullString
	if err := row.Scan(&iteration, &stateJSON, &checksumNS); err != nil {
		if err == sql.ErrNoRows {
			return nil, nil
		}
		return nil, fmt.Errorf("LoadLatest: scan checkpoint: %w", err)
	}

	if checksumNS.Valid && checksumNS.String != "" {
		computedSum := sha256.Sum256([]byte(stateJSON))
		computed := hex.EncodeToString(computedSum[:])
		if computed != checksumNS.String {
			return nil, fmt.Errorf("LoadLatest: checksum mismatch for thread %s (stored %s, computed %s)", threadID, checksumNS.String, computed)
		}
	}

	var messages []StrategicMessage
	if err := json.Unmarshal([]byte(stateJSON), &messages); err != nil {
		return nil, fmt.Errorf("LoadLatest: unmarshal state: %w", err)
	}

	trow := m.db.QueryRow(
		`SELECT model, metadata FROM threads WHERE thread_id = ?`, threadID,
	)
	var model, metaJSON string
	if err := trow.Scan(&model, &metaJSON); err != nil && err != sql.ErrNoRows {
		return nil, fmt.Errorf("LoadLatest: scan thread: %w", err)
	}

	var metadata map[string]any
	if metaJSON != "" {
		if err := json.Unmarshal([]byte(metaJSON), &metadata); err != nil {
			metadata = map[string]any{}
		}
	} else {
		metadata = map[string]any{}
	}

	return &ThreadSnapshot{
		Iteration: iteration,
		Messages:  messages,
		Model:     model,
		Metadata:  metadata,
	}, nil
}

// CompleteThread marks a thread as completed, preventing further resumes.
func (m *CheckpointManager) CompleteThread(threadID string) error {
	_, err := m.db.Exec(
		`UPDATE threads SET status = 'completed', updated_at = CURRENT_TIMESTAMP
                 WHERE thread_id = ?`,
		threadID,
	)
	if err != nil {
		return fmt.Errorf("CompleteThread: exec: %w", err)
	}
	return nil
}

// DB returns the underlying *sql.DB so callers can share the connection for
// additional tables (e.g. PairingStore) without opening a second handle.
func (m *CheckpointManager) DB() *sql.DB {
	return m.db
}

// ListResumable returns all active threads that have at least one checkpoint,
// ordered by most-recently-updated first.
func (m *CheckpointManager) ListResumable() ([]ResumableThread, error) {
	rows, err := m.db.Query(`
		SELECT t.thread_id, t.model, t.updated_at, MAX(c.iteration) AS latest_iteration
		FROM threads t
		JOIN checkpoints c ON t.thread_id = c.thread_id
		WHERE t.status != 'completed'
		GROUP BY t.thread_id
		ORDER BY t.updated_at DESC
	`)
	if err != nil {
		return nil, fmt.Errorf("ListResumable: query: %w", err)
	}
	defer func() { _ = rows.Close() }()

	var result []ResumableThread
	for rows.Next() {
		var r ResumableThread
		if err := rows.Scan(&r.ThreadID, &r.Model, &r.UpdatedAt, &r.LatestIteration); err != nil {
			return nil, fmt.Errorf("ListResumable: scan: %w", err)
		}
		result = append(result, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("ListResumable: final iteration: %w", err)
	}
	return result, nil
}

func truncate(s string, n int) string {
	runes := []rune(s)
	if len(runes) <= n {
		return s
	}
	return string(runes[:n]) + "..."
}
