//nolint:testpackage // exercises unexported injected write path.
package memory

import (
	"errors"
	"os"
	"strings"
	"testing"
	"time"
)

type failingJournalFile struct{}

func (failingJournalFile) WriteString(string) (int, error) {
	return 0, errors.New("forced write failure")
}

func (failingJournalFile) Close() error {
	return nil
}

func TestWriteJournalEntryReportsWriteFailure(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	err := writeJournalEntry(
		root,
		"entry",
		time.Date(2026, 7, 19, 12, 0, 0, 0, time.UTC),
		os.MkdirAll,
		func(string, int, os.FileMode) (journalFile, error) {
			return failingJournalFile{}, nil
		},
	)

	if err == nil {
		t.Fatal("expected write error")
	}
	if !strings.Contains(err.Error(), "write journal") {
		t.Fatalf("error = %q, want write journal context", err)
	}
}
