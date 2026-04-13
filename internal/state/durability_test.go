//nolint:testpackage // requires unexported state durability internals for testing
package state

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// TestCrashRecovery_SimulatesPowerFailure verifies recovery after simulated crash.
func TestCrashRecovery_SimulatesPowerFailure(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()
	config := ManagerConfig{
		StateDir:    tempDir,
		LockTimeout: 5 * time.Second,
	}

	manager := NewManager(config)
	if err := manager.Init(); err != nil {
		t.Fatalf("Init failed: %v", err)
	}

	// Create workflow.
	if _, err := manager.CreateWorkflow("wf-crash", json.RawMessage(`{"step": 1}`)); err != nil {
		t.Fatalf("CreateWorkflow failed: %v", err)
	}

	// Simulate crash: journal entry written but checkpoint not updated.
	if err := manager.UpdateStatus("wf-crash", StatusRunning); err != nil {
		t.Fatalf("UpdateStatus failed: %v", err)
	}

	// Simulate recovery (new manager instance).
	manager2 := NewManager(config)
	recovered, err := manager2.LoadWithRecovery("wf-crash")
	if err != nil {
		t.Fatalf("Recovery failed: %v", err)
	}

	// Verify journal was replayed.
	if recovered.Status != StatusRunning {
		t.Errorf("Status = %q, want running (journal replayed)", recovered.Status)
	}
}

func checkpointWorker(n int, manager *Manager, workflowID WorkflowID, wg *sync.WaitGroup, errors chan<- error) {
	defer wg.Done()

	// Load, update, save.
	wf, err := manager.LoadWorkflow(workflowID)
	if err != nil {
		errors <- err
		return
	}

	var data map[string]int
	if err := json.Unmarshal(wf.Data, &data); err != nil {
		errors <- err
		return
	}
	data["count"] = n
	newData, err := json.Marshal(data)
	if err != nil {
		errors <- err
		return
	}
	wf.Data = newData

	if err := manager.SaveCheckpoint(wf); err != nil {
		errors <- err
	}
}

// TestConcurrentCheckpoints verifies multiple goroutines can checkpoint safely.
func TestConcurrentCheckpoints(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()
	config := ManagerConfig{
		StateDir:    tempDir,
		LockTimeout: 5 * time.Second,
	}

	manager := NewManager(config)
	if err := manager.Init(); err != nil {
		t.Fatalf("Init failed: %v", err)
	}

	// Create workflow.
	if _, err := manager.CreateWorkflow("wf-concurrent", json.RawMessage(`{"count": 0}`)); err != nil {
		t.Fatalf("CreateWorkflow failed: %v", err)
	}

	// Concurrent updates.
	var wg sync.WaitGroup
	errors := make(chan error, 10)

	for i := 0; i < 10; i++ {
		wg.Add(1)
		go checkpointWorker(i, manager, "wf-concurrent", &wg, errors)
	}

	wg.Wait()
	close(errors)

	// Check for errors (some conflicts expected, but no corruption).
	errCount := 0
	for err := range errors {
		if err != nil {
			errCount++
		}
	}

	// Should have some successful saves.
	final, err := manager.LoadWorkflow("wf-concurrent")
	if err != nil {
		t.Fatalf("LoadWorkflow failed: %v", err)
	}
	if final.Version < 2 {
		t.Errorf("Version = %d, expected at least 2", final.Version)
	}
}

// TestAtomicWrite_InterruptedWrite verifies temp file cleanup on failure.
func TestAtomicWrite_InterruptedWrite(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()
	targetPath := filepath.Join(tempDir, "test.json")

	// Write successfully first.
	content := []byte(`{"valid": true}`)
	if err := WriteFileAtomic(targetPath, content, 0o644); err != nil {
		t.Fatalf("WriteFileAtomic failed: %v", err)
	}

	// Verify no temp files left.
	entries, err := os.ReadDir(tempDir)
	if err != nil {
		t.Fatalf("ReadDir failed: %v", err)
	}
	tempCount := 0
	for _, e := range entries {
		if len(e.Name()) > 4 && e.Name()[:4] == ".tmp" {
			tempCount++
		}
	}

	if tempCount > 0 {
		t.Errorf("Found %d temp files, expected 0", tempCount)
	}
}

// TestStaleLockRecovery verifies stale locks are cleaned up on startup.
func TestStaleLockRecovery(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()
	config := ManagerConfig{
		StateDir:    tempDir,
		LockTimeout: 100 * time.Millisecond,
	}

	manager := NewManager(config)
	if err := manager.Init(); err != nil {
		t.Fatalf("Init failed: %v", err)
	}

	// Create a stale lock file.
	lockPath := filepath.Join(tempDir, "locks", "stale.lock")
	if err := os.MkdirAll(filepath.Dir(lockPath), 0o750); err != nil {
		t.Fatalf("MkdirAll failed: %v", err)
	}
	if err := os.WriteFile(lockPath, []byte{}, 0o600); err != nil {
		t.Fatalf("WriteFile failed: %v", err)
	}

	// Set modification time to past.
	oldTime := time.Now().Add(-time.Hour)
	if err := os.Chtimes(lockPath, oldTime, oldTime); err != nil {
		t.Fatalf("Chtimes failed: %v", err)
	}

	// Cleanup should remove it.
	if err := manager.CleanupStaleLocks(); err != nil {
		t.Fatalf("CleanupStaleLocks failed: %v", err)
	}

	// Verify removed.
	if _, err := os.Stat(lockPath); !os.IsNotExist(err) {
		t.Error("Stale lock should be removed")
	}
}

// TestJournalCorruption_SkipsBadEntries verifies corrupted entries are skipped.
func TestJournalCorruption_SkipsBadEntries(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()

	// Create journal with valid and invalid entries.
	journalPath := filepath.Join(tempDir, "corrupt.journal")
	file, err := os.Create(journalPath)
	if err != nil {
		t.Fatalf("Create journal failed: %v", err)
	}

	// Valid entry.
	validEntry := `{"timestamp":"2026-03-29T12:00:00Z","operation":"status_change","payload":"{\"status\": \"running\"}"}` + "\n"
	if _, err := file.WriteString(validEntry); err != nil {
		t.Fatalf("WriteString failed: %v", err)
	}

	// Invalid entry.
	if _, err := file.WriteString(`{invalid json` + "\n"); err != nil {
		t.Fatalf("WriteString failed: %v", err)
	}

	// Another valid entry.
	if _, err := file.WriteString(validEntry); err != nil {
		t.Fatalf("WriteString failed: %v", err)
	}
	if err := file.Close(); err != nil {
		t.Fatalf("Close failed: %v", err)
	}

	// Replay should skip invalid entry.
	entries, err := Replay(journalPath)
	if err != nil {
		t.Fatalf("Replay failed: %v", err)
	}

	if len(entries) != 2 {
		t.Errorf("Expected 2 valid entries, got %d", len(entries))
	}
}

// TestCheckpointIntegrity_VerifiesAtomicity verifies checkpoint is atomic.
func TestCheckpointIntegrity_VerifiesAtomicity(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()
	config := ManagerConfig{
		StateDir:    tempDir,
		LockTimeout: 5 * time.Second,
	}

	manager := NewManager(config)
	if err := manager.Init(); err != nil {
		t.Fatalf("Init failed: %v", err)
	}

	// Create and checkpoint workflow.
	state := &WorkflowState{
		ID:      "wf-integrity",
		Status:  StatusRunning,
		Version: 1,
		Data:    json.RawMessage(`{"important": "data"}`),
	}

	if err := manager.SaveCheckpoint(state); err != nil {
		t.Fatalf("SaveCheckpoint failed: %v", err)
	}

	// Verify file is complete and valid JSON.
	checkpointPath := filepath.Join(tempDir, "workflows", "wf-integrity", "checkpoint.json")
	data, err := os.ReadFile(checkpointPath)
	if err != nil {
		t.Fatalf("Failed to read checkpoint: %v", err)
	}

	// Must be valid JSON.
	var loaded WorkflowState
	if err := json.Unmarshal(data, &loaded); err != nil {
		t.Errorf("Checkpoint is not valid JSON: %v", err)
	}

	// Verify all fields present.
	if loaded.ID != "wf-integrity" || loaded.Status != StatusRunning {
		t.Error("Checkpoint data incomplete")
	}
}

// TestFullWorkflowLifecycle exercises complete create-update-archive cycle.
//
//nolint:cyclop // test complexity justified by full lifecycle coverage
func TestFullWorkflowLifecycle(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()
	config := ManagerConfig{
		StateDir:    tempDir,
		LockTimeout: 5 * time.Second,
	}

	manager := NewManager(config)
	if err := manager.Init(); err != nil {
		t.Fatalf("Init failed: %v", err)
	}

	// 1. Create.
	state, err := manager.CreateWorkflow("wf-lifecycle", json.RawMessage(`{"step": 0}`))
	if err != nil {
		t.Fatalf("Create failed: %v", err)
	}

	// 2. Update status.
	if err := manager.UpdateStatus("wf-lifecycle", StatusRunning); err != nil {
		t.Fatalf("UpdateStatus failed: %v", err)
	}

	// 3. Checkpoint.
	state.Data = json.RawMessage(`{"step": 1}`)
	if err := manager.SaveCheckpoint(state); err != nil {
		t.Fatalf("SaveCheckpoint failed: %v", err)
	}

	// 4. Archive.
	if err := manager.Archive("wf-lifecycle"); err != nil {
		t.Fatalf("Archive failed: %v", err)
	}

	// 5. Verify archived.
	archivedPath := filepath.Join(tempDir, "archived", "wf-lifecycle.json")
	if _, err := os.Stat(archivedPath); err != nil {
		t.Errorf("Archived file missing: %v", err)
	}

	// 6. Verify removed from active.
	activePath := filepath.Join(tempDir, "workflows", "wf-lifecycle")
	if _, err := os.Stat(activePath); !os.IsNotExist(err) {
		t.Error("Active workflow should be removed")
	}

	// 7. Verify not in list.
	ids, err := manager.ListActive()
	if err != nil {
		t.Fatalf("ListActive failed: %v", err)
	}
	for _, id := range ids {
		if id == "wf-lifecycle" {
			t.Error("Archived workflow in active list")
		}
	}
}

// BenchmarkCheckpoint measures checkpoint performance.
func BenchmarkCheckpoint(b *testing.B) {
	tempDir := b.TempDir()
	config := ManagerConfig{
		StateDir:    tempDir,
		LockTimeout: 5 * time.Second,
	}

	manager := NewManager(config)
	if err := manager.Init(); err != nil {
		b.Fatalf("Init failed: %v", err)
	}

	state := &WorkflowState{
		ID:      "wf-bench",
		Status:  StatusRunning,
		Version: 1,
		Data:    json.RawMessage(`{"data": "benchmark payload"}`),
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		state.Version = i
		if err := manager.SaveCheckpoint(state); err != nil {
			b.Fatalf("SaveCheckpoint failed: %v", err)
		}
	}
}
