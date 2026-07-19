package memory

import (
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// DailyJournalPath returns the path of the current day's journal file.
// Exposed so callers can check existence without importing path/filepath.
func DailyJournalPath(storageRoot string, t time.Time) string {
	date := t.Format("2006-01-02")
	return filepath.Join(storageRoot, "workspace", "journal", date+".md")
}

// GetJournalContinuity reads the last maxChars bytes from the current day's
// journal and returns a formatted continuity block for injection into the
// system prompt. Returns an empty string if the journal is absent or empty.
//
// When the journal is absent it is initialised with a date header so that
// subsequent writes have a file to append to.
func GetJournalContinuity(storageRoot string, maxChars int) string {
	continuity, _ := GetJournalContinuityWithError(storageRoot, maxChars)
	return continuity
}

// GetJournalContinuityWithError reads the current day's journal continuity block.
// Missing and empty journals are expected non-errors and return an empty block.
func GetJournalContinuityWithError(storageRoot string, maxChars int) (string, error) {
	now := time.Now()
	journalPath := DailyJournalPath(storageRoot, now)
	hasContent, err := ensureJournalReady(journalPath, now)
	if err != nil || !hasContent {
		return "", err
	}

	return readJournalContinuity(journalPath, maxChars)
}

func ensureJournalReady(journalPath string, now time.Time) (bool, error) {
	info, err := os.Stat(journalPath)
	if err != nil {
		if !os.IsNotExist(err) {
			return false, fmt.Errorf("stat journal %s: %w", journalPath, err)
		}
		if initErr := initializeJournal(journalPath, now); initErr != nil {
			return false, initErr
		}
		return false, nil
	}
	if !info.IsDir() && info.Size() == 0 {
		if initErr := initializeJournal(journalPath, now); initErr != nil {
			return false, initErr
		}
		return false, nil
	}
	return true, nil
}

func readJournalContinuity(journalPath string, maxChars int) (string, error) {
	data, err := os.ReadFile(journalPath)
	if err != nil {
		return "", fmt.Errorf("read journal %s: %w", journalPath, err)
	}
	if len(data) == 0 {
		return "", nil
	}

	snippet := string(data)
	if len(snippet) > maxChars {
		snippet = snippet[len(snippet)-maxChars:]
		// Trim to the next newline so we don't start mid-line.
		if nl := indexOf(snippet, '\n'); nl != -1 {
			snippet = snippet[nl+1:]
		}
	}

	return "\n### RECENT CONTINUITY (FROM DAILY JOURNAL):\n..." + snippet + "\n", nil
}

func initializeJournal(journalPath string, t time.Time) error {
	if err := os.MkdirAll(filepath.Dir(journalPath), 0o755); err != nil {
		return fmt.Errorf("create journal directory %s: %w", filepath.Dir(journalPath), err)
	}
	date := t.Format("2006-01-02")
	if err := os.WriteFile(journalPath, []byte("# "+date+"\n\n"), 0o600); err != nil {
		return fmt.Errorf("initialize journal %s: %w", journalPath, err)
	}
	return nil
}

// WriteJournalEntry appends a consolidation entry to the current day's journal.
// Returns true on success.
func WriteJournalEntry(storageRoot, entry string) bool {
	return WriteJournalEntryWithError(storageRoot, entry) == nil
}

// WriteJournalEntryWithError appends a consolidation entry to the current day's
// journal and returns the underlying filesystem failure, if any.
func WriteJournalEntryWithError(storageRoot, entry string) error {
	return writeJournalEntry(storageRoot, entry, time.Now(), os.MkdirAll, openJournalFile)
}

type journalFile interface {
	WriteString(string) (int, error)
	Close() error
}

func openJournalFile(name string, flag int, perm os.FileMode) (journalFile, error) {
	f, err := os.OpenFile(name, flag, perm)
	if err != nil {
		return nil, fmt.Errorf("open journal file: %w", err)
	}
	return f, nil
}

func writeJournalEntry(storageRoot, entry string, t time.Time, mkdirAll func(string, os.FileMode) error, openFile func(string, int, os.FileMode) (journalFile, error)) error {
	journalPath := DailyJournalPath(storageRoot, t)
	if err := mkdirAll(filepath.Dir(journalPath), 0o755); err != nil {
		return fmt.Errorf("create journal directory %s: %w", filepath.Dir(journalPath), err)
	}

	ts := t.Format("15:04:05")
	line := fmt.Sprintf("\n### CONSOLIDATION [%s]\n%s\n", ts, entry)

	f, err := openFile(journalPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("open journal %s: %w", journalPath, err)
	}
	defer func() { _ = f.Close() }()

	if _, err = f.WriteString(line); err != nil {
		return fmt.Errorf("write journal %s: %w", journalPath, err)
	}
	return nil
}

func indexOf(s string, b byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] == b {
			return i
		}
	}
	return -1
}
