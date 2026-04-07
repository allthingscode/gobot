package state

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestOpenJournal_CreatesFile(t *testing.T) {
	tempDir := t.TempDir()

	journal, err := OpenJournal(tempDir, "wf-123")
	if err != nil {
		t.Fatalf("OpenJournal failed: %v", err)
	}
	defer journal.Close()

	journalPath := filepath.Join(tempDir, "wf-123.journal")
	if _, err := os.Stat(journalPath); err != nil {
		t.Errorf("Journal file does not exist: %v", err)
	}
}

func TestJournal_AppendAndReplay(t *testing.T) {
	tempDir := t.TempDir()

	journal, err := OpenJournal(tempDir, "wf-456")
	if err != nil {
		t.Fatalf("OpenJournal failed: %v", err)
	}

	entry1 := JournalEntry{
		Timestamp: time.Now(),
		Operation: "status_change",
		Payload:   json.RawMessage(`{"status": "running"}`),
	}
	if err := journal.Append(entry1); err != nil {
		t.Fatalf("Append failed: %v", err)
	}

	entry2 := JournalEntry{
		Timestamp: time.Now(),
		Operation: "data_update",
		Payload:   json.RawMessage(`{"key": "value"}`),
	}
	if err := journal.Append(entry2); err != nil {
		t.Fatalf("Append failed: %v", err)
	}

	journal.Close()

	journalPath := filepath.Join(tempDir, "wf-456.journal")
	entries, err := Replay(journalPath)
	if err != nil {
		t.Fatalf("Replay failed: %v", err)
	}

	if len(entries) != 2 {
		t.Errorf("Expected 2 entries, got %d", len(entries))
	}
	if entries[0].Operation != "status_change" {
		t.Errorf("First entry operation = %q, want status_change", entries[0].Operation)
	}
	if entries[1].Operation != "data_update" {
		t.Errorf("Second entry operation = %q, want data_update", entries[1].Operation)
	}
}

func TestReplay_NonExistent(t *testing.T) {
	tempDir := t.TempDir()
	nonExistent := filepath.Join(tempDir, "nonexistent.journal")

	entries, err := Replay(nonExistent)
	if err != nil {
		t.Fatalf("Replay should not error for non-existent: %v", err)
	}
	if len(entries) != 0 {
		t.Errorf("Expected 0 entries for non-existent, got %d", len(entries))
	}
}

func TestTruncate_RemovesFile(t *testing.T) {
	tempDir := t.TempDir()
	journalPath := filepath.Join(tempDir, "to-truncate.journal")

	if err := os.WriteFile(journalPath, []byte("data"), 0600); err != nil {
		t.Fatalf("Failed to create file: %v", err)
	}

	if err := Truncate(journalPath); err != nil {
		t.Fatalf("Truncate failed: %v", err)
	}

	if _, err := os.Stat(journalPath); !os.IsNotExist(err) {
		t.Error("Journal file should be removed after Truncate")
	}
}

func TestRecoverWorkflow(t *testing.T) {
	tempDir := t.TempDir()

	journal, _ := OpenJournal(tempDir, "wf-recover")
	_ = journal.Append(JournalEntry{
		Timestamp: time.Now(),
		Operation: "status_change",
		Payload:   json.RawMessage(`{"status": "running"}`),
	})
	_ = journal.Append(JournalEntry{
		Timestamp: time.Now(),
		Operation: "data_update",
		Payload:   json.RawMessage(`{"progress": 50}`),
	})
	journal.Close()

	state := &WorkflowState{ID: "wf-recover", Status: StatusPending}
	err := RecoverWorkflow(tempDir, "wf-recover", state)
	if err != nil {
		t.Fatalf("RecoverWorkflow failed: %v", err)
	}

	if state.Status != StatusRunning {
		t.Errorf("Status = %q, want running", state.Status)
	}

	var data map[string]interface{}
	_ = json.Unmarshal(state.Data, &data)
	if data["progress"] != float64(50) {
		t.Errorf("Data progress = %v, want 50", data["progress"])
	}
}
