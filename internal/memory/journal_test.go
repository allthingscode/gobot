package memory_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/memory"
)

// ── DailyJournalPath ──────────────────────────────────────────────────────────

func TestDailyJournalPath_Format(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	ts := time.Date(2026, 3, 27, 12, 0, 0, 0, time.UTC)
	got := memory.DailyJournalPath(root, ts)
	want := filepath.Join(root, "workspace", "journal", "2026-03-27.md")
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

// ── GetJournalContinuity ──────────────────────────────────────────────────────

func TestGetJournalContinuity_ReturnsEmptyWhenMissing(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	got := memory.GetJournalContinuity(root, 1000)
	if got != "" {
		t.Errorf("expected empty string for missing journal, got %q", got)
	}
	// Should have created the file for future writes.
	path := memory.DailyJournalPath(root, time.Now())
	if _, err := os.Stat(path); err != nil {
		t.Errorf("expected journal file to be initialised, got error: %v", err)
	}
}

func TestGetJournalContinuity_ReturnsContent(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	journalPath := memory.DailyJournalPath(root, time.Now())
	if err := os.MkdirAll(filepath.Dir(journalPath), 0o755); err != nil {
		t.Fatal(err)
	}
	content := "# Today\n\n### CONSOLIDATION [10:00:00]\nfirst entry\n"
	if err := os.WriteFile(journalPath, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}

	got := memory.GetJournalContinuity(root, 10000)
	if !strings.Contains(got, "RECENT CONTINUITY") {
		t.Errorf("expected continuity header, got %q", got)
	}
	if !strings.Contains(got, "first entry") {
		t.Errorf("expected journal content, got %q", got)
	}
}

func TestGetJournalContinuity_TruncatesToMaxChars(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	journalPath := memory.DailyJournalPath(root, time.Now())
	if err := os.MkdirAll(filepath.Dir(journalPath), 0o755); err != nil {
		t.Fatal(err)
	}
	// Write a 200-char file; maxChars=50 should truncate to the end.
	content := "# Journal\n\n" + strings.Repeat("abcdefghij\n", 18)
	if err := os.WriteFile(journalPath, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}

	got := memory.GetJournalContinuity(root, 50)
	// Should not contain the full content.
	if strings.Contains(got, "# Journal") {
		t.Error("expected content to be truncated; header still present")
	}
}

func TestGetJournalContinuity_NoNewlineInTruncatedPortion(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	journalPath := memory.DailyJournalPath(root, time.Now())
	if err := os.MkdirAll(filepath.Dir(journalPath), 0o755); err != nil {
		t.Fatal(err)
	}
	// Header, then a long run of chars with no newline at the end.
	// maxChars=20 will grab the last 20 bytes of "xxxx...xxxx" — no newline there.
	content := "# Journal\n\n" + strings.Repeat("x", 200)
	if err := os.WriteFile(journalPath, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}

	got := memory.GetJournalContinuity(root, 20)
	// Should still return the truncated snippet (indexOf returns -1, no trim).
	if !strings.Contains(got, "RECENT CONTINUITY") {
		t.Errorf("expected continuity block even with no newline in snippet, got %q", got)
	}
}

func TestGetJournalContinuity_EmptyFileReturnsEmpty(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	journalPath := memory.DailyJournalPath(root, time.Now())
	if err := os.MkdirAll(filepath.Dir(journalPath), 0o755); err != nil {
		t.Fatal(err)
	}
	// Create an empty file.
	if err := os.WriteFile(journalPath, []byte{}, 0o600); err != nil {
		t.Fatal(err)
	}

	got := memory.GetJournalContinuity(root, 1000)
	if got != "" {
		t.Errorf("expected empty string for empty journal, got %q", got)
	}
}

// ── WriteJournalEntry ─────────────────────────────────────────────────────────

func TestWriteJournalEntry_CreatesAndAppends(t *testing.T) {
	t.Parallel()
	root := t.TempDir()

	ok := memory.WriteJournalEntry(root, "first consolidation")
	if !ok {
		t.Fatal("expected WriteJournalEntry to return true")
	}

	journalPath := memory.DailyJournalPath(root, time.Now())
	data, err := os.ReadFile(journalPath)
	if err != nil {
		t.Fatalf("expected journal file to exist: %v", err)
	}
	if !strings.Contains(string(data), "first consolidation") {
		t.Errorf("entry not found in journal: %s", string(data))
	}
}

func TestWriteJournalEntry_AppendsTwice(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	memory.WriteJournalEntry(root, "entry one")
	memory.WriteJournalEntry(root, "entry two")

	journalPath := memory.DailyJournalPath(root, time.Now())
	data, _ := os.ReadFile(journalPath)
	if !strings.Contains(string(data), "entry one") || !strings.Contains(string(data), "entry two") {
		t.Errorf("expected both entries, got:\n%s", string(data))
	}
}

func TestWriteJournalEntry_ContainsCONSOLIDATIONHeader(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	memory.WriteJournalEntry(root, "test entry")

	journalPath := memory.DailyJournalPath(root, time.Now())
	data, _ := os.ReadFile(journalPath)
	if !strings.Contains(string(data), "### CONSOLIDATION [") {
		t.Errorf("expected CONSOLIDATION header in journal, got:\n%s", string(data))
	}
}
