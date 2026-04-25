//nolint:testpackage // requires unexported state internals for testing
package state

import (
	"os"
	"path/filepath"
	"testing"
)

func TestWriteFileAtomic_Success(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()
	targetPath := filepath.Join(tempDir, "subdir", "test.txt")
	content := []byte("hello, world")

	err := WriteFileAtomic(targetPath, content, 0o640)
	if err != nil {
		t.Fatalf("WriteFileAtomic failed: %v", err)
	}

	// Verify file exists and has correct content.
	got, err := os.ReadFile(targetPath)
	if err != nil {
		t.Fatalf("Failed to read file: %v", err)
	}
	if string(got) != string(content) {
		t.Errorf("Content = %q, want %q", got, content)
	}

	// Verify permissions.
	info, err := os.Stat(targetPath)
	if err != nil {
		t.Fatalf("Failed to stat file: %v", err)
	}
	// Note: Windows may not respect Unix permissions exactly.
	if info.Mode().Perm()&0o200 == 0 {
		t.Errorf("File not writable")
	}
}

func TestWriteFileAtomic_CreatesParentDir(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()
	targetPath := filepath.Join(tempDir, "a", "b", "c", "test.txt")
	content := []byte("nested content")

	err := WriteFileAtomic(targetPath, content, 0o644)
	if err != nil {
		t.Fatalf("WriteFileAtomic failed: %v", err)
	}

	// Verify file exists.
	if _, err := os.Stat(targetPath); err != nil {
		t.Errorf("File does not exist: %v", err)
	}
}

func TestWriteFileAtomic_OverwritesExisting(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()
	targetPath := filepath.Join(tempDir, "existing.txt")

	// Create initial file.
	if err := os.WriteFile(targetPath, []byte("old"), 0o600); err != nil {
		t.Fatalf("Failed to create initial file: %v", err)
	}

	// Overwrite with atomic write.
	newContent := []byte("new content")
	err := WriteFileAtomic(targetPath, newContent, 0o600)
	if err != nil {
		t.Fatalf("WriteFileAtomic failed: %v", err)
	}

	got, err := os.ReadFile(targetPath)
	if err != nil {
		t.Fatalf("Failed to read file: %v", err)
	}
	if string(got) != string(newContent) {
		t.Errorf("Content = %q, want %q", got, newContent)
	}
}

func TestReadFileJSON_Success(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()
	jsonPath := filepath.Join(tempDir, "test.json")

	// Write test JSON.
	content := `{"id": "wf-123", "status": "running", "version": 1}`
	if err := os.WriteFile(jsonPath, []byte(content), 0o600); err != nil {
		t.Fatalf("Failed to write test file: %v", err)
	}

	var state WorkflowState
	err := ReadFileJSON(jsonPath, &state)
	if err != nil {
		t.Fatalf("ReadFileJSON failed: %v", err)
	}

	if state.ID != "wf-123" {
		t.Errorf("ID = %q, want %q", state.ID, "wf-123")
	}
	if state.Status != StatusRunning {
		t.Errorf("Status = %q, want %q", state.Status, StatusRunning)
	}
	if state.Version != 1 {
		t.Errorf("Version = %d, want %d", state.Version, 1)
	}
}

func TestReadFileJSON_FileNotFound(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()
	nonExistent := filepath.Join(tempDir, "nonexistent.json")

	var state WorkflowState
	err := ReadFileJSON(nonExistent, &state)
	if err == nil {
		t.Error("Expected error for non-existent file, got nil")
	}
}

func TestReadFileJSON_InvalidJSON(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()
	jsonPath := filepath.Join(tempDir, "invalid.json")

	// Write invalid JSON.
	if err := os.WriteFile(jsonPath, []byte("not json"), 0o600); err != nil {
		t.Fatalf("Failed to write test file: %v", err)
	}

	var state WorkflowState
	err := ReadFileJSON(jsonPath, &state)
	if err == nil {
		t.Error("Expected error for invalid JSON, got nil")
	}
}

func TestWriteFileJSON_Success(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()
	jsonPath := filepath.Join(tempDir, "output.json")

	state := WorkflowState{
		ID:      "wf-456",
		Status:  StatusPending,
		Version: 2,
	}

	err := WriteFileJSON(jsonPath, state, 0o644)
	if err != nil {
		t.Fatalf("WriteFileJSON failed: %v", err)
	}

	// Read back and verify.
	var got WorkflowState
	if err := ReadFileJSON(jsonPath, &got); err != nil {
		t.Fatalf("Failed to read back JSON: %v", err)
	}

	if got.ID != state.ID {
		t.Errorf("ID = %q, want %q", got.ID, state.ID)
	}
	if got.Status != state.Status {
		t.Errorf("Status = %q, want %q", got.Status, state.Status)
	}
	if got.Version != state.Version {
		t.Errorf("Version = %d, want %d", got.Version, state.Version)
	}
}
