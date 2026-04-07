package state

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// ManagerConfig configures the state manager.
type ManagerConfig struct {
	StateDir    string
	LockTimeout time.Duration
	MaxRetries  int
}

// DefaultManagerConfig returns sensible defaults.
func DefaultManagerConfig() ManagerConfig {
	return ManagerConfig{
		StateDir:    "state",
		LockTimeout: 30 * time.Second,
		MaxRetries:  3,
	}
}

// Manager orchestrates workflow state persistence.
type Manager struct {
	config ManagerConfig
}

// NewManager creates a new state manager.
func NewManager(config ManagerConfig) *Manager {
	return &Manager{config: config}
}

// Init ensures the state directory structure exists.
func (m *Manager) Init() error {
	dirs := []string{
		m.config.StateDir,
		filepath.Join(m.config.StateDir, "workflows"),
		filepath.Join(m.config.StateDir, "locks"),
		filepath.Join(m.config.StateDir, "archived"),
	}

	for _, dir := range dirs {
		if err := os.MkdirAll(dir, 0o750); err != nil {
			return fmt.Errorf("creating directory %s: %w", dir, err)
		}
	}

	return nil
}

// CreateWorkflow initializes a new workflow with state.
func (m *Manager) CreateWorkflow(id WorkflowID, initialData json.RawMessage) (*WorkflowState, error) {
	now := time.Now()
	state := &WorkflowState{
		ID:        id,
		Status:    StatusPending,
		Version:   1,
		CreatedAt: now,
		UpdatedAt: now,
		Data:      initialData,
	}

	if err := m.SaveCheckpoint(state); err != nil {
		return nil, fmt.Errorf("saving initial checkpoint: %w", err)
	}

	return state, nil
}

// SaveCheckpoint persists workflow state atomically.
func (m *Manager) SaveCheckpoint(state *WorkflowState) error {
	// Acquire lock.
	lock, err := AcquireLock(
		filepath.Join(m.config.StateDir, "locks"),
		state.ID,
		m.config.LockTimeout,
	)
	if err != nil {
		return fmt.Errorf("acquiring lock: %w", err)
	}
	defer func() { _ = lock.Release() }()

	// Update timestamp and version.
	state.UpdatedAt = time.Now()
	state.Version++

	// Write checkpoint atomically. WriteFileJSON calls WriteFileAtomic which
	// creates the parent directory (workflows/{id}/) automatically.
	checkpointPath := m.checkpointPath(state.ID)
	if err := WriteFileJSON(checkpointPath, state, 0o640); err != nil {
		return fmt.Errorf("writing checkpoint: %w", err)
	}

	// Truncate journal after successful checkpoint.
	_ = Truncate(m.journalPath(state.ID)) // Ignore error - journal may not exist

	return nil
}

// LoadWorkflow restores workflow state from checkpoint.
func (m *Manager) LoadWorkflow(id WorkflowID) (*WorkflowState, error) {
	checkpointPath := m.checkpointPath(id)

	var state WorkflowState
	if err := ReadFileJSON(checkpointPath, &state); err != nil {
		if os.IsNotExist(err) {
			return nil, fmt.Errorf("workflow %s not found", id)
		}
		return nil, fmt.Errorf("reading checkpoint: %w", err)
	}

	return &state, nil
}

// LoadWithRecovery loads workflow and replays any journal entries.
func (m *Manager) LoadWithRecovery(id WorkflowID) (*WorkflowState, error) {
	// Load base checkpoint.
	state, err := m.LoadWorkflow(id)
	if err != nil {
		return nil, err
	}

	// Check for journal entries to replay.
	journalPath := m.journalPath(id)
	if _, err := os.Stat(journalPath); err == nil {
		// Journal exists - replay it.
		if err := RecoverWorkflow(
			filepath.Join(m.config.StateDir, "workflows"),
			id,
			state,
		); err != nil {
			return nil, fmt.Errorf("recovery failed: %w", err)
		}
	}

	return state, nil
}

// UpdateStatus changes workflow status with journaling.
func (m *Manager) UpdateStatus(id WorkflowID, status WorkflowStatus) error {
	// Open journal. OpenJournal creates {journalDir}/{id}.journal.
	journalDir := filepath.Join(m.config.StateDir, "workflows")
	journal, err := OpenJournal(journalDir, id)
	if err != nil {
		return fmt.Errorf("opening journal: %w", err)
	}
	defer journal.Close()

	// Append status change.
	entry := JournalEntry{
		Timestamp: time.Now(),
		Operation: "status_change",
		Payload:   json.RawMessage(fmt.Sprintf(`{"status": %q}`, status)),
	}

	if err := journal.Append(entry); err != nil {
		return fmt.Errorf("appending to journal: %w", err)
	}

	return nil
}

// Archive moves completed workflow to archive directory.
func (m *Manager) Archive(id WorkflowID) error {
	lock, err := AcquireLock(
		filepath.Join(m.config.StateDir, "locks"),
		id,
		m.config.LockTimeout,
	)
	if err != nil {
		return fmt.Errorf("acquiring lock: %w", err)
	}
	defer func() { _ = lock.Release() }()

	// Move checkpoint to archive.
	src := m.checkpointPath(id)
	dst := filepath.Join(m.config.StateDir, "archived", string(id)+".json")

	if err := os.Rename(src, dst); err != nil {
		return fmt.Errorf("archiving checkpoint: %w", err)
	}

	// Remove journal and workflow directory.
	_ = os.Remove(m.journalPath(id))
	_ = os.RemoveAll(filepath.Join(m.config.StateDir, "workflows", string(id)))

	return nil
}

// ListActive returns all active (non-archived) workflow IDs.
func (m *Manager) ListActive() ([]WorkflowID, error) {
	workflowsDir := filepath.Join(m.config.StateDir, "workflows")

	entries, err := os.ReadDir(workflowsDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("reading workflows directory: %w", err)
	}

	var ids []WorkflowID
	for _, entry := range entries {
		if entry.IsDir() {
			ids = append(ids, WorkflowID(entry.Name()))
		}
	}

	return ids, nil
}

// CleanupStaleLocks removes stale locks on startup.
func (m *Manager) CleanupStaleLocks() error {
	lockDir := filepath.Join(m.config.StateDir, "locks")
	return CleanupStaleLocks(lockDir, m.config.LockTimeout)
}

// checkpointPath returns the path for a workflow's checkpoint file.
// Each workflow gets its own subdirectory: workflows/{id}/checkpoint.json
func (m *Manager) checkpointPath(id WorkflowID) string {
	return filepath.Join(m.config.StateDir, "workflows", string(id), "checkpoint.json")
}

// journalPath returns the path for a workflow's journal file.
// Journals are flat files: workflows/{id}.journal
// This matches what OpenJournal and RecoverWorkflow use.
func (m *Manager) journalPath(id WorkflowID) string {
	return filepath.Join(m.config.StateDir, "workflows", string(id)+".journal")
}
