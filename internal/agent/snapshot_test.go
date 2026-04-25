//nolint:testpackage // requires unexported mock types for testing
package agent

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSnapshot(t *testing.T) {
	t.Parallel()

	storageRoot, sessionDir, files := setupSnapshotTest(t)

	ticket := HandoffTicket{
		TargetSpecialist: "Reviewer",
		TaskID:           "F-081",
	}

	// Test CreateSnapshot
	if err := CreateSnapshot(storageRoot, ticket); err != nil {
		t.Fatalf("CreateSnapshot failed: %v", err)
	}

	snapshots, err := ListSnapshots(storageRoot)
	if err != nil {
		t.Fatalf("ListSnapshots failed: %v", err)
	}
	verifySnapshotMetadata(t, snapshots)

	snap := snapshots[0]
	verifySnapshotFiles(t, sessionDir, snap.Name, files)

	// Test deduplication
	if err := CreateSnapshot(storageRoot, ticket); err != nil {
		t.Fatalf("CreateSnapshot failed on second call: %v", err)
	}
	verifyDeduplication(t, storageRoot)

	verifyRestore(t, storageRoot, sessionDir, snap.Name)
}

func verifySnapshotMetadata(t *testing.T, snapshots []SnapshotMetadata) {
	t.Helper()
	if len(snapshots) != 1 {
		t.Fatalf("expected 1 snapshot, got %d", len(snapshots))
	}
	snap := snapshots[0]
	if snap.Specialist != "Reviewer" || snap.TaskID != "F-081" {
		t.Errorf("unexpected snapshot metadata: %+v", snap)
	}
}

func verifySnapshotFiles(t *testing.T, sessionDir, snapName string, files map[string]string) {
	t.Helper()
	snapshotDir := filepath.Join(sessionDir, "history", snapName)
	for name, expected := range files {
		content, err := os.ReadFile(filepath.Join(snapshotDir, name))
		if err != nil {
			t.Errorf("failed to read %s from snapshot: %v", name, err)
		}
		if string(content) != expected {
			t.Errorf("unexpected content in %s: got %q, want %q", name, string(content), expected)
		}
	}
}

func verifyDeduplication(t *testing.T, storageRoot string) {
	t.Helper()
	snapshots, _ := ListSnapshots(storageRoot)
	if len(snapshots) != 1 {
		t.Fatalf("expected still 1 snapshot due to deduplication, got %d", len(snapshots))
	}
}

func setupSnapshotTest(t *testing.T) (storageRoot, sessionDir string, files map[string]string) {
	t.Helper()
	tempDir, err := os.MkdirTemp("", "gobot-snapshot-test")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}
	t.Cleanup(func() { os.RemoveAll(tempDir) })

	storageRoot = tempDir
	sessionDir = filepath.Join(storageRoot, ".private", "session")
	if err := os.MkdirAll(sessionDir, 0o755); err != nil {
		t.Fatalf("failed to create session dir: %v", err)
	}

	// Create dummy session files
	files = map[string]string{
		"session_state.json": `{"state": "active"}`,
		"task.md":            "# Task 1",
		"review_report.md":   "LGTM",
	}
	for name, content := range files {
		if err := os.WriteFile(filepath.Join(sessionDir, name), []byte(content), 0o600); err != nil {
			t.Fatalf("failed to write %s: %v", name, err)
		}
	}
	return storageRoot, sessionDir, files
}

func verifyRestore(t *testing.T, storageRoot, sessionDir, snapName string) {
	t.Helper()
	// Test RestoreSnapshot
	// Modify current session files
	if err := os.WriteFile(filepath.Join(sessionDir, "session_state.json"), []byte(`{"state": "corrupted"}`), 0o600); err != nil {
		t.Fatalf("failed to modify file: %v", err)
	}
	// Add a new file that should be deleted
	if err := os.WriteFile(filepath.Join(sessionDir, "garbage.txt"), []byte("delete me"), 0o600); err != nil {
		t.Fatalf("failed to write garbage: %v", err)
	}

	if err := RestoreSnapshot(storageRoot, snapName); err != nil {
		t.Fatalf("RestoreSnapshot failed: %v", err)
	}

	// Verify session files restored
	content, _ := os.ReadFile(filepath.Join(sessionDir, "session_state.json"))
	if string(content) != `{"state": "active"}` {
		t.Errorf("restore failed, got %q, want %q", string(content), `{"state": "active"}`)
	}

	if _, err := os.Stat(filepath.Join(sessionDir, "garbage.txt")); !os.IsNotExist(err) {
		t.Errorf("garbage.txt was not deleted during restore")
	}
}
