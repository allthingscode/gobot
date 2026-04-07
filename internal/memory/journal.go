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
	journalPath := DailyJournalPath(storageRoot, time.Now())

	info, err := os.Stat(journalPath)
	if err != nil || info.Size() == 0 {
		// Initialise the journal file.
		if mkErr := os.MkdirAll(filepath.Dir(journalPath), 0o755); mkErr == nil {
			date := time.Now().Format("2006-01-02")
			_ = os.WriteFile(journalPath, []byte("# "+date+"\n\n"), 0o600)
		}
		return ""
	}

	data, err := os.ReadFile(journalPath)
	if err != nil || len(data) == 0 {
		return ""
	}

	snippet := string(data)
	if len(snippet) > maxChars {
		snippet = snippet[len(snippet)-maxChars:]
		// Trim to the next newline so we don't start mid-line.
		if nl := indexOf(snippet, '\n'); nl != -1 {
			snippet = snippet[nl+1:]
		}
	}

	return "\n### RECENT CONTINUITY (FROM DAILY JOURNAL):\n..." + snippet + "\n"
}

// WriteJournalEntry appends a consolidation entry to the current day's journal.
// Returns true on success.
func WriteJournalEntry(storageRoot string, entry string) bool {
	journalPath := DailyJournalPath(storageRoot, time.Now())
	if err := os.MkdirAll(filepath.Dir(journalPath), 0o755); err != nil {
		return false
	}

	ts := time.Now().Format("15:04:05")
	line := fmt.Sprintf("\n### CONSOLIDATION [%s]\n%s\n", ts, entry)

	f, err := os.OpenFile(journalPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return false
	}
	defer f.Close()

	_, err = f.WriteString(line)
	return err == nil
}

func indexOf(s string, b byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] == b {
			return i
		}
	}
	return -1
}
