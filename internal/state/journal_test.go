//nolint:testpackage // requires unexported journal internals for testing
package state

import (
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

func TestOpenJournal_CreatesFile(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()

	journal, err := OpenJournal(tempDir, "wf-123")
	if err != nil {
		t.Fatalf("OpenJournal failed: %v", err)
	}
	defer func() { _ = journal.Close() }()

	journalPath := filepath.Join(tempDir, "wf-123.journal")
	if _, err := os.Stat(journalPath); err != nil {
		t.Errorf("Journal file does not exist: %v", err)
	}
}

func TestJournal_AppendAndReplay(t *testing.T) {
	t.Parallel()
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

	_ = journal.Close()

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
	t.Parallel()
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
	t.Parallel()
	tempDir := t.TempDir()
	journalPath := filepath.Join(tempDir, "to-truncate.journal")

	if err := os.WriteFile(journalPath, []byte("data"), 0o600); err != nil {
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
	t.Parallel()
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
	_ = journal.Close()

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

//nolint:gocognit,cyclop // Fixture matrix verifies corruption context, causes and atomic results together.
func TestReplay_Records(t *testing.T) {
	t.Parallel()
	status := `{"timestamp":"2026-10-20T12:00:00Z","operation":"status_change","payload":{"status":"running"}}`
	data := `{"timestamp":"2026-10-20T13:00:00Z","operation":"data_update","payload":{"value":2}}`
	corrupt := `{"private-payload":`
	tests := []struct {
		name      string
		content   string
		missing   bool
		line      int
		scanError bool
		want      []JournalEntry
	}{
		{name: "ordered", content: status + "\n" + data + "\n", want: []JournalEntry{
			{Timestamp: time.Date(2026, 10, 20, 12, 0, 0, 0, time.UTC), Operation: "status_change", Payload: json.RawMessage(`{"status":"running"}`)},
			{Timestamp: time.Date(2026, 10, 20, 13, 0, 0, 0, time.UTC), Operation: "data_update", Payload: json.RawMessage(`{"value":2}`)},
		}},
		{name: "empty"},
		{name: "missing", missing: true},
		{name: "valid unterminated", content: data, want: []JournalEntry{
			{Timestamp: time.Date(2026, 10, 20, 13, 0, 0, 0, time.UTC), Operation: "data_update", Payload: json.RawMessage(`{"value":2}`)},
		}},
		{name: "malformed first", content: corrupt + "\n" + data + "\n", line: 1},
		{name: "malformed interior", content: status + "\n" + corrupt + "\n" + data + "\n", line: 2},
		{name: "malformed last", content: status + "\n" + corrupt + "\n", line: 2},
		{name: "torn final", content: status + "\n" + corrupt, line: 2},
		{name: "blank", content: status + "\n\n" + data + "\n", line: 2},
		{name: "oversized", content: status + "\n" + strings.Repeat(" ", 70*1024), scanError: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			path := filepath.Join(t.TempDir(), "replay.journal")
			if !tt.missing {
				if err := os.WriteFile(path, []byte(tt.content), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			got, err := Replay(path)
			if tt.line > 0 || tt.scanError {
				if err == nil {
					t.Fatal("expected corruption error")
				}
				if got != nil {
					t.Fatalf("partial entries returned: %v", got)
				}
				if tt.line > 0 {
					if !strings.Contains(err.Error(), fmt.Sprintf("decoding journal %q line %d:", path, tt.line)) {
						t.Fatalf("missing path/line: %v", err)
					}
					var syntax *json.SyntaxError
					if !errors.As(err, &syntax) {
						t.Fatalf("missing syntax cause: %v", err)
					}
					if strings.Contains(err.Error(), "private-payload") {
						t.Fatalf("payload disclosed: %v", err)
					}
				} else if !strings.Contains(err.Error(), "scanning journal:") {
					t.Fatalf("missing scanner context: %v", err)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("entries = %#v, want %#v", got, tt.want)
			}
		})
	}
}

//nolint:gocognit,cyclop // Fixture matrix checks recovery errors and unchanged state together.
func TestRecoverWorkflow_Records(t *testing.T) {
	t.Parallel()
	prefix := "{\"timestamp\":\"2026-10-20T12:00:00Z\",\"operation\":\"status_change\",\"payload\":{\"status\":\"running\"}}\n" +
		"{\"timestamp\":\"2026-10-20T13:00:00Z\",\"operation\":\"data_update\",\"payload\":{\"value\":2}}\n"
	for _, tt := range []struct {
		name      string
		content   string
		missing   bool
		wantError bool
	}{
		{name: "malformed first", content: "{\n" + prefix, wantError: true},
		{name: "malformed complete after prefix", content: prefix + "{\n", wantError: true},
		{name: "torn final after prefix", content: prefix + "{", wantError: true},
		{name: "missing", missing: true},
		{name: "valid ordered", content: prefix},
	} {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			dir := t.TempDir()
			path := filepath.Join(dir, "wf.journal")
			if !tt.missing {
				if err := os.WriteFile(path, []byte(tt.content), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			initial := WorkflowState{ID: "wf", Status: StatusPending, Data: json.RawMessage(`{"original":true}`), UpdatedAt: time.Date(2026, 10, 19, 0, 0, 0, 0, time.UTC)}
			state := initial
			state.Data = append(json.RawMessage(nil), initial.Data...)
			err := RecoverWorkflow(dir, "wf", &state)
			if tt.wantError {
				if err == nil {
					t.Fatal("expected recovery error")
				}
				var syntax *json.SyntaxError
				if !strings.Contains(err.Error(), "replaying journal:") || !strings.Contains(err.Error(), fmt.Sprintf("%q", path)) || !errors.As(err, &syntax) {
					t.Fatalf("missing recovery context/cause: %v", err)
				}
			} else if err != nil {
				t.Fatal(err)
			}
			if tt.wantError || tt.missing {
				if !reflect.DeepEqual(state, initial) {
					t.Fatalf("state changed: %#v, want %#v", state, initial)
				}
			} else if state.Status != StatusRunning || string(state.Data) != `{"value":2}` || !state.UpdatedAt.Equal(time.Date(2026, 10, 20, 13, 0, 0, 0, time.UTC)) {
				t.Fatalf("incorrect recovered state: %#v", state)
			}
		})
	}
}
