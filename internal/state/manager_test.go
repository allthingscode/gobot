//nolint:testpackage // requires unexported manager internals for testing
package state

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

//nolint:gocognit,cyclop // Table matrices inspect persisted lifecycle state and failure evidence together.
func TestManager_ArchiveMaterializesJournal(t *testing.T) {
	t.Parallel()
	for _, journaled := range []bool{false, true} {
		t.Run(fmt.Sprintf("journaled=%t", journaled), func(t *testing.T) {
			t.Parallel()
			mgr := NewManager(ManagerConfig{StateDir: t.TempDir(), LockTimeout: time.Second})
			if err := mgr.Init(); err != nil {
				t.Fatal(err)
			}
			id := WorkflowID("archive-state")
			if _, err := mgr.CreateWorkflow(id, json.RawMessage(`{"step":0}`)); err != nil {
				t.Fatal(err)
			}
			if journaled {
				if err := mgr.UpdateStatus(id, StatusCompleted); err != nil {
					t.Fatal(err)
				}
				journal, err := OpenJournal(filepath.Join(mgr.config.StateDir, "workflows"), id)
				if err != nil {
					t.Fatal(err)
				}
				if err := journal.Append(JournalEntry{Timestamp: time.Now(), Operation: "data_update", Payload: json.RawMessage(`{"step":3}`)}); err != nil {
					t.Fatal(err)
				}
				if err := journal.Close(); err != nil {
					t.Fatal(err)
				}
			}
			want, err := mgr.LoadWithRecovery(id)
			if err != nil {
				t.Fatal(err)
			}
			checkpoint, err := mgr.LoadWorkflow(id)
			if err != nil {
				t.Fatal(err)
			}
			if checkpoint.Status != StatusPending {
				t.Fatalf("checkpoint-only status: %s", checkpoint.Status)
			}
			if err := mgr.Archive(id); err != nil {
				t.Fatal(err)
			}
			var got WorkflowState
			if err := ReadFileJSON(filepath.Join(mgr.config.StateDir, "archived", string(id)+".json"), &got); err != nil {
				t.Fatal(err)
			}
			if strings.Join(strings.Fields(string(got.Data)), "") != strings.Join(strings.Fields(string(want.Data)), "") {
				t.Fatalf("archive data = %s, want %s", got.Data, want.Data)
			}
			got.Data = want.Data
			if !reflect.DeepEqual(&got, want) {
				t.Fatalf("archive = %+v, want %+v", got, want)
			}
			ids, err := mgr.ListActive()
			if err != nil || len(ids) != 0 {
				t.Fatalf("active: %v, %v", ids, err)
			}
			if _, err := os.Stat(mgr.journalPath(id)); !os.IsNotExist(err) {
				t.Fatalf("journal remains: %v", err)
			}
		})
	}
}

//nolint:gocognit,cyclop // Table matrices inspect persisted lifecycle state and failure evidence together.
func TestManager_ArchiveFailurePreservesEvidence(t *testing.T) {
	t.Parallel()
	for _, failure := range []string{"read", "replay", "write"} {
		t.Run(failure, func(t *testing.T) {
			t.Parallel()
			mgr := NewManager(ManagerConfig{StateDir: t.TempDir(), LockTimeout: time.Second})
			if err := mgr.Init(); err != nil {
				t.Fatal(err)
			}
			id := WorkflowID("retry-archive")
			if _, err := mgr.CreateWorkflow(id, json.RawMessage(`{"step":2}`)); err != nil {
				t.Fatal(err)
			}
			if err := mgr.UpdateStatus(id, StatusFailed); err != nil {
				t.Fatal(err)
			}
			checkpointPath, journalPath := mgr.checkpointPath(id), mgr.journalPath(id)
			originalCheckpoint, err := os.ReadFile(checkpointPath)
			if err != nil {
				t.Fatal(err)
			}
			originalJournal, err := os.ReadFile(journalPath)
			if err != nil {
				t.Fatal(err)
			}
			archivePath := filepath.Join(mgr.config.StateDir, "archived", string(id)+".json")
			restore := obstructArchive(t, failure, checkpointPath, journalPath, archivePath, originalCheckpoint, originalJournal)
			beforeCheckpoint, err := os.ReadFile(checkpointPath)
			if err != nil {
				t.Fatal(err)
			}
			beforeJournal, err := os.ReadFile(journalPath)
			if err != nil {
				t.Fatal(err)
			}
			err = mgr.Archive(id)
			if err == nil || errors.Unwrap(err) == nil || !strings.Contains(err.Error(), "archiv") {
				t.Fatalf("archive error: %v", err)
			}
			afterCheckpoint, err := os.ReadFile(checkpointPath)
			if err != nil {
				t.Fatal(err)
			}
			afterJournal, err := os.ReadFile(journalPath)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(beforeCheckpoint, afterCheckpoint) || !bytes.Equal(beforeJournal, afterJournal) {
				t.Fatal("archive failure modified evidence")
			}
			restore()
			want, err := mgr.LoadWithRecovery(id)
			if err != nil {
				t.Fatal(err)
			}
			if want.Status != StatusFailed || strings.Join(strings.Fields(string(want.Data)), "") != `{"step":2}` {
				t.Fatalf("recovery: %+v", want)
			}
			if err := mgr.Archive(id); err != nil {
				t.Fatal(err)
			}
			var archived WorkflowState
			if err := ReadFileJSON(archivePath, &archived); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(&archived, want) {
				t.Fatalf("retry archive: %+v, want %+v", archived, want)
			}
		})
	}
}

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

func TestDefaultManagerConfig(t *testing.T) {
	t.Parallel()
	cfg := DefaultManagerConfig()
	if cfg.StateDir != "state" {
		t.Fatalf("StateDir = %q", cfg.StateDir)
	}
	if cfg.LockTimeout != 30*time.Second {
		t.Fatalf("LockTimeout = %v", cfg.LockTimeout)
	}
	if cfg.MaxRetries != 3 {
		t.Fatalf("MaxRetries = %d", cfg.MaxRetries)
	}
}

func TestLoadWorkflowMissing(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()
	manager := NewManager(ManagerConfig{StateDir: tempDir, LockTimeout: 5 * time.Second})
	_ = manager.Init()
	_, err := manager.LoadWorkflow("nonexistent-wf")
	if err == nil {
		t.Fatal("expected error loading non-existent workflow")
	}
}

func TestManagerCleanupStaleLocks(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()
	manager := NewManager(ManagerConfig{StateDir: tempDir, LockTimeout: 5 * time.Second})
	_ = manager.Init()
	if err := manager.CleanupStaleLocks(); err != nil {
		t.Fatalf("CleanupStaleLocks: %v", err)
	}
}

func TestManagerListActiveEmpty(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()
	manager := NewManager(ManagerConfig{StateDir: tempDir, LockTimeout: 5 * time.Second})
	_ = manager.Init()
	ids, err := manager.ListActive()
	if err != nil || len(ids) != 0 {
		t.Fatalf("ListActive empty = %v, %v", ids, err)
	}
}

//nolint:gocognit,cyclop // Deterministic filesystem fixtures cover three independent failure classes.
func obstructArchive(t *testing.T, failure, checkpointPath, journalPath, archivePath string, originalCheckpoint, originalJournal []byte) func() {
	t.Helper()
	var restore func()
	switch failure {
	case "read":
		if err := os.WriteFile(checkpointPath, []byte(`{`), 0o600); err != nil {
			t.Fatal(err)
		}
		restore = func() {
			if err := os.WriteFile(checkpointPath, originalCheckpoint, 0o600); err != nil { // #nosec G703 -- fixed workflow ID under t.TempDir.
				t.Fatal(err)
			}
		}
	case "replay":
		bad := append(bytes.Clone(originalJournal), []byte("{\"operation\":\"status_change\",\"payload\":42}\n")...)
		if err := os.WriteFile(journalPath, bad, 0o600); err != nil { // #nosec G703 -- fixed workflow ID under t.TempDir.
			t.Fatal(err)
		}
		restore = func() {
			if err := os.WriteFile(journalPath, originalJournal, 0o600); err != nil { // #nosec G703 -- fixed workflow ID under t.TempDir.
				t.Fatal(err)
			}
		}
	case "write":
		if err := os.Mkdir(archivePath, 0o750); err != nil {
			t.Fatal(err)
		}
		blocker := filepath.Join(archivePath, "blocker")
		if err := os.WriteFile(blocker, nil, 0o600); err != nil {
			t.Fatal(err)
		}
		restore = func() {
			if err := os.Remove(blocker); err != nil {
				t.Fatal(err)
			}
			if err := os.Remove(archivePath); err != nil {
				t.Fatal(err)
			}
		}
	}
	return restore
}
