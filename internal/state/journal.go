package state

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// Journal manages append-only operation log for a workflow.
type Journal struct {
	path string
	file *os.File
}

// OpenJournal opens or creates a journal file for the given workflow.
func OpenJournal(journalDir string, id WorkflowID) (*Journal, error) {
	journalPath := filepath.Join(journalDir, string(id)+".journal")

	// Ensure directory exists.
	if err := os.MkdirAll(journalDir, 0o750); err != nil {
		return nil, fmt.Errorf("creating journal directory: %w", err)
	}

	// Open for append, create if doesn't exist.
	file, err := os.OpenFile(journalPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o640)
	if err != nil {
		return nil, fmt.Errorf("opening journal file: %w", err)
	}

	return &Journal{path: journalPath, file: file}, nil
}

// Append writes a journal entry atomically.
func (j *Journal) Append(entry JournalEntry) error {
	data, err := json.Marshal(entry)
	if err != nil {
		return fmt.Errorf("marshaling journal entry: %w", err)
	}

	// Write with newline delimiter for line-by-line reading.
	line := append(data, '\n') //nolint:gocritic // intentional: append newline to new slice
	if _, err := j.file.Write(line); err != nil {
		return fmt.Errorf("writing journal entry: %w", err)
	}

	// Sync to disk for durability.
	return j.file.Sync()
}

// Close closes the journal file.
func (j *Journal) Close() error {
	if j.file != nil {
		return j.file.Close()
	}
	return nil
}

// Replay reads all journal entries and returns them in order.
func Replay(journalPath string) ([]JournalEntry, error) {
	file, err := os.Open(journalPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil // No journal = no entries
		}
		return nil, fmt.Errorf("opening journal: %w", err)
	}
	defer file.Close()

	var entries []JournalEntry
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		var entry JournalEntry
		if err := json.Unmarshal(scanner.Bytes(), &entry); err != nil {
			continue // Skip corrupted entries
		}
		entries = append(entries, entry)
	}

	return entries, scanner.Err()
}

// Truncate removes the journal file after successful checkpoint.
func Truncate(journalPath string) error {
	return os.Remove(journalPath)
}

// RecoverWorkflow replays journal entries to reconstruct workflow state.
func RecoverWorkflow(journalDir string, id WorkflowID, state *WorkflowState) error {
	journalPath := filepath.Join(journalDir, string(id)+".journal")
	entries, err := Replay(journalPath)
	if err != nil {
		return fmt.Errorf("replaying journal: %w", err)
	}

	// Apply each entry to rebuild state.
	for _, entry := range entries {
		if err := applyEntry(state, entry); err != nil {
			return fmt.Errorf("applying entry %s: %w", entry.Operation, err)
		}
	}

	return nil
}

// applyEntry applies a single journal entry to workflow state.
func applyEntry(state *WorkflowState, entry JournalEntry) error {
	switch entry.Operation {
	case "status_change":
		var payload struct {
			Status WorkflowStatus `json:"status"`
		}
		if err := json.Unmarshal(entry.Payload, &payload); err != nil {
			return err
		}
		state.Status = payload.Status
		state.UpdatedAt = entry.Timestamp
	case "data_update":
		state.Data = entry.Payload
		state.UpdatedAt = entry.Timestamp
	}
	return nil
}
