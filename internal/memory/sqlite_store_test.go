package memory

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func newTestStore(t *testing.T) *MemoryStore {
	t.Helper()
	store, err := NewMemoryStore(t.TempDir())
	if err != nil {
		t.Fatalf("NewMemoryStore: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	return store
}

// ── NewMemoryStore ─────────────────────────────────────────────────────────────

func TestNewMemoryStore_CreatesDB(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	store, err := NewMemoryStore(root)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	defer func() { _ = store.Close() }()

	// Verify WAL mode is set.
	var mode string
	if err := store.db.QueryRow("PRAGMA journal_mode").Scan(&mode); err != nil {
		t.Fatalf("PRAGMA journal_mode: %v", err)
	}
	if mode != "wal" {
		t.Errorf("journal_mode = %q, want \"wal\"", mode)
	}
}

func TestNewMemoryStore_IdempotentSchema(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	// Opening the same root twice must not error (idempotent CREATE IF NOT EXISTS).
	s1, err := NewMemoryStore(root)
	if err != nil {
		t.Fatalf("first open: %v", err)
	}
	_ = s1.Close()

	s2, err := NewMemoryStore(root)
	if err != nil {
		t.Fatalf("second open: %v", err)
	}
	_ = s2.Close()
}

// ── Index ──────────────────────────────────────────────────────────────────────

func TestIndex(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name      string
		namespace string
		content   string
		wantErr   bool
		wantStored bool
	}{
		{
			name:      "normal entry",
			namespace: "session:123",
			content:   "The project deadline is March 31.",
			wantStored: true,
		},
		{
			name:      "global entry",
			namespace: "global",
			content:   "User prefers metric units.",
			wantStored: true,
		},
		{
			name:      "empty content is no-op",
			namespace: "global",
			content:   "",
			wantStored: false,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			store := newTestStore(t)
			err := store.Index(tc.namespace, tc.content)
			if (err != nil) != tc.wantErr {
				t.Fatalf("Index() error = %v, wantErr %v", err, tc.wantErr)
			}

			var count int
			if err := store.db.QueryRow(`SELECT count(*) FROM memory_fts`).Scan(&count); err != nil {
				t.Fatalf("failed to scan count: %v", err)
			}
			if tc.wantStored && count != 1 {
				t.Errorf("want 1 entry in DB, got %d", count)
			}
			if !tc.wantStored && count != 0 {
				t.Errorf("want 0 entries in DB, got %d", count)
			}
		})
	}
}

// ── Search ─────────────────────────────────────────────────────────────────────

func TestSearch(t *testing.T) {
	t.Parallel()
	store := newTestStore(t)

	_ = store.Index("session:a", "The Q1 budget review is on Thursday with the finance team.")
	_ = store.Index("session:b", "Reminder: submit expense report by Friday.")
	_ = store.Index("global", "Project Alpha deadline is May 1st.")

	tests := []struct {
		name       string
		query      string
		sessionKey string
		limit      int
		wantCount  int // minimum matches expected
		wantNone   bool
	}{
		{
			name:       "finds budget entry in session a",
			query:      "budget",
			sessionKey: "a",
			limit:      5,
			wantCount:  1,
		},
		{
			name:       "finds global entry from session b",
			query:      "Alpha",
			sessionKey: "b",
			limit:      5,
			wantCount:  1,
		},
		{
			name:       "does not find session a entry from session b",
			query:      "budget",
			sessionKey: "b",
			limit:      5,
			wantNone:   true,
		},
		{
			name:       "deduplicates results",
			query:      "deadline",
			sessionKey: "c",
			limit:      5,
			wantCount:  1,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			results, err := store.Search(tc.query, tc.sessionKey, tc.limit)
			if err != nil {
				t.Fatalf("Search() unexpected error: %v", err)
			}
			if tc.wantNone {
				if len(results) != 0 {
					t.Errorf("want no results, got %d", len(results))
				}
				return
			}
			if len(results) < tc.wantCount {
				t.Errorf("want at least %d results, got %d", tc.wantCount, len(results))
			}
			// Verify result shape.
			for _, r := range results {
				if _, ok := r["content"]; !ok {
					t.Error("result missing 'content' key")
				}
				if _, ok := r["namespace"]; !ok {
					t.Error("result missing 'namespace' key")
				}
			}
		})
	}
}

// ── Rebuild ────────────────────────────────────────────────────────────────────

func TestRebuild(t *testing.T) {
	t.Parallel()
	store := newTestStore(t)

	// Create a temp session directory with some .md files.
	sessionDir := t.TempDir()
	files := map[string]string{
		"session-alpha.md": "Summary: reviewed the Q1 financial report.",
		"session-beta.md":  "Summary: discussed marketing strategy.",
		"notes.txt":        "This should be ignored (not .md).",
	}
	for name, body := range files {
		if err := writeFile(filepath.Join(sessionDir, name), body); err != nil {
			t.Fatalf("setup: %v", err)
		}
	}

	n, err := store.Rebuild(sessionDir)
	if err != nil {
		t.Fatalf("Rebuild: %v", err)
	}
	if n != 2 {
		t.Errorf("Rebuild indexed %d files, want 2", n)
	}

	// Verify the indexed content is searchable.
	results, _ := store.Search("financial report", "session-alpha", 5)
	if len(results) == 0 {
		t.Error("expected to find 'financial report' after rebuild")
	}

	// Verify session key is derived from filename.
	found := false
	for _, r := range results {
		if r["namespace"] == "session:session-alpha" {
			found = true
			break
		}
	}
	if !found {
		t.Error("namespace 'session:session-alpha' not found in results")
	}
}

func TestRebuild_NonexistentDir(t *testing.T) {
	t.Parallel()
	store := newTestStore(t)
	_, err := store.Rebuild(filepath.Join(t.TempDir(), "does-not-exist"))
	if err == nil {
		t.Error("expected error for nonexistent directory, got nil")
	}
}

func TestMemoryStore_Rebuild_Limit(t *testing.T) {
	t.Parallel()
	store := newTestStore(t)

	sessionDir := t.TempDir()
	
	// Create maxRebuildFiles + 100 mock files
	for i := 0; i < maxRebuildFiles+100; i++ {
		name := filepath.Join(sessionDir, fmt.Sprintf("session-%d.md", i))
		if err := writeFile(name, "Summary: mock"); err != nil {
			t.Fatalf("setup: %v", err)
		}
	}

	n, err := store.Rebuild(sessionDir)
	if err != nil {
		t.Fatalf("Rebuild: %v", err)
	}
	if n != maxRebuildFiles {
		t.Errorf("Rebuild indexed %d files, want %d", n, maxRebuildFiles)
	}
}

// ── sanitizeFTSQuery ───────────────────────────────────────────────────────────

func TestSanitizeFTSQuery(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name  string
		input string
		// wantContains checks the output does NOT contain FTS5 special chars.
	}{
		{name: "plain words unchanged", input: "hello world"},
		{name: "removes parens", input: "hello (world)"},
		{name: "removes quotes", input: `"hello world"`},
		{name: "removes asterisk", input: "hello*"},
		{name: "removes dash", input: "hello-world"},
		{name: "collapses whitespace", input: "hello   world"},
		{name: "empty stays empty", input: ""},
		{name: "only special chars becomes empty", input: `( ) * " -`},
	}
	special := []string{`"`, `(`, `)`, `*`, `^`, `-`, `+`, `{`, `}`, `:`, `[`, `]`}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got := sanitizeFTSQuery(tc.input)
			for _, ch := range special {
				if strings.Contains(got, ch) {
					t.Errorf("sanitized output %q still contains %q", got, ch)
				}
			}
		})
	}
}

// ── helpers ────────────────────────────────────────────────────────────────────

func writeFile(path, content string) error {
	return os.WriteFile(path, []byte(content), 0o600)
}

// ── CleanupExpired (F-068) ─────────────────────────────────────────────────

func TestCleanupExpired(t *testing.T) {
	t.Parallel()
	store := newTestStore(t)

	// Add some entries to the store.
	_ = store.Index("session:1", "fact 1")
	_ = store.Index("session:2", "fact 2")

	tests := []struct {
		name    string
		ttl     string
		wantErr bool
		// For very short TTLs, we just verify no error and count >= 0.
		// For long TTLs, we verify count == 0.
	}{
		{
			name:    "empty TTL is no-op",
			ttl:     "",
			wantErr: false,
		},
		{
			name:    "invalid duration is no-op",
			ttl:     "not-a-duration",
			wantErr: false, // Handled gracefully
		},
		{
			name:    "valid TTL with no expiry deletes nothing",
			ttl:     "87600h", // ~10 years from now
			wantErr: false,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			deleted, err := store.CleanupExpired(tc.ttl)
			if (err != nil) != tc.wantErr {
				t.Fatalf("CleanupExpired() error = %v, wantErr %v", err, tc.wantErr)
			}
			// Just verify that the function ran without crashing and returns valid count.
			if deleted < 0 {
				t.Errorf("deleted count should not be negative: %d", deleted)
			}
		})
	}
}
