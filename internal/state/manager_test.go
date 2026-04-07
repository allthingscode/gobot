package state

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestManager_Init(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()
	config := ManagerConfig{StateDir: tempDir}

	manager := NewManager(config)
	_ = manager.Init()

	// Verify directories exist.
	dirs := []string{"workflows", "locks", "archived"}
	for _, dir := range dirs {
		path := filepath.Join(tempDir, dir)
		if _, err := os.Stat(path); err != nil {
			t.Errorf("Directory %s does not exist: %v", dir, err)
		}
	}
}

func TestManager_CreateAndLoad(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()
	config := ManagerConfig{
		StateDir:    tempDir,
		LockTimeout: 5 * time.Second,
	}

	manager := NewManager(config)
	_ = manager.Init()

	// Create workflow.
	data := json.RawMessage(`{"key": "value"}`)
	created, err := manager.CreateWorkflow("wf-test", data)
	if err != nil {
		t.Fatalf("CreateWorkflow failed: %v", err)
	}

	if created.Status != StatusPending {
		t.Errorf("Status = %q, want pending", created.Status)
	}

	// Load workflow.
	loaded, err := manager.LoadWorkflow("wf-test")
	if err != nil {
		t.Fatalf("LoadWorkflow failed: %v", err)
	}

	if loaded.ID != created.ID {
		t.Errorf("ID = %q, want %q", loaded.ID, created.ID)
	}
}

func TestManager_SaveCheckpoint(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()
	config := ManagerConfig{
		StateDir:    tempDir,
		LockTimeout: 5 * time.Second,
	}

	manager := NewManager(config)
	_ = manager.Init()

	// Create initial state.
	state := &WorkflowState{
		ID:      "wf-checkpoint",
		Status:  StatusRunning,
		Version: 1,
		Data:    json.RawMessage(`{"progress": 0}`),
	}

	// Save checkpoint.
	if err := manager.SaveCheckpoint(state); err != nil {
		t.Fatalf("SaveCheckpoint failed: %v", err)
	}

	if state.Version != 2 {
		t.Errorf("Version = %d, want 2", state.Version)
	}

	// Verify file exists at workflows/{id}/checkpoint.json.
	checkpointPath := filepath.Join(tempDir, "workflows", "wf-checkpoint", "checkpoint.json")
	if _, err := os.Stat(checkpointPath); err != nil {
		t.Errorf("Checkpoint file does not exist: %v", err)
	}
}

func TestManager_UpdateStatus(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()
	config := ManagerConfig{
		StateDir:    tempDir,
		LockTimeout: 5 * time.Second,
	}

	manager := NewManager(config)
	_ = manager.Init()
	_, _ = manager.CreateWorkflow("wf-status", nil)

	// Update status.
	_ = manager.UpdateStatus("wf-status", StatusRunning)

	// Verify journal file exists at workflows/{id}.journal (flat file).
	journalPath := filepath.Join(tempDir, "workflows", "wf-status.journal")
	if _, err := os.Stat(journalPath); err != nil {
		t.Errorf("Journal file does not exist: %v", err)
	}
}

func TestManager_LoadWithRecovery(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()
	config := ManagerConfig{
		StateDir:    tempDir,
		LockTimeout: 5 * time.Second,
	}

	manager := NewManager(config)
	_ = manager.Init()

	// Create workflow.
	_, _ = manager.CreateWorkflow("wf-recover", json.RawMessage(`{"initial": true}`))

	// Add journal entries.
	_ = manager.UpdateStatus("wf-recover", StatusRunning)

	// Load with recovery.
	state, err := manager.LoadWithRecovery("wf-recover")
	if err != nil {
		t.Fatalf("LoadWithRecovery failed: %v", err)
	}

	if state.Status != StatusRunning {
		t.Errorf("Status = %q, want running", state.Status)
	}
}

func TestManager_Archive(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()
	config := ManagerConfig{
		StateDir:    tempDir,
		LockTimeout: 5 * time.Second,
	}

	manager := NewManager(config)
	_ = manager.Init()
	_, _ = manager.CreateWorkflow("wf-archive", nil)

	// Archive.
	if err := manager.Archive("wf-archive"); err != nil {
		t.Fatalf("Archive failed: %v", err)
	}

	// Verify moved to archive.
	archivedPath := filepath.Join(tempDir, "archived", "wf-archive.json")
	if _, err := os.Stat(archivedPath); err != nil {
		t.Errorf("Archived file does not exist: %v", err)
	}

	// Verify workflow directory removed from active.
	activePath := filepath.Join(tempDir, "workflows", "wf-archive")
	if _, err := os.Stat(activePath); !os.IsNotExist(err) {
		t.Error("Active workflow directory should be removed after archive")
	}
}

func TestManager_ListActive(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()
	config := ManagerConfig{
		StateDir:    tempDir,
		LockTimeout: 5 * time.Second,
	}

	manager := NewManager(config)
	_ = manager.Init()

	// Create workflows.
	_, _ = manager.CreateWorkflow("wf-1", nil)
	_, _ = manager.CreateWorkflow("wf-2", nil)

	// List active.
	ids, err := manager.ListActive()
	if err != nil {
		t.Fatalf("ListActive failed: %v", err)
	}

	if len(ids) != 2 {
		t.Errorf("Expected 2 active workflows, got %d", len(ids))
	}
}
