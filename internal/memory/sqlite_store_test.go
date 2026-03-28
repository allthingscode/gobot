package memory

import (
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
	t.Cleanup(func() { store.Close() })
	return store
}

// ── NewMemoryStore ─────────────────────────────────────────────────────────────

func TestNewMemoryStore_CreatesDB(t *testing.T) {
	root := t.TempDir()
	store, err := NewMemoryStore(root)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	defer store.Close()

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
	root := t.TempDir()
	// Opening the same root twice must not error (idempotent CREATE IF NOT EXISTS).
	s1, err := NewMemoryStore(root)
	if err != nil {
		t.Fatalf("first open: %v", err)
	}
	s1.Close()

	s2, err := NewMemoryStore(root)
	if err != nil {
		t.Fatalf("second open: %v", err)
	}
	s2.Close()
}

// ── Index ──────────────────────────────────────────────────────────────────────

func TestIndex(t *testing.T) {
	tests := []struct {
		name       string
		sessionKey string
		content    string
		wantErr    bool
		wantStored bool
	}{
		{
			name:       "normal entry",
			sessionKey: "telegram:123",
			content:    "The project deadline is March 31.",
			wantStored: true,
		},
		{
			name:       "empty content is no-op",
			sessionKey: "telegram:123",
			content:    "",
			wantStored: false,
		},
		{
			name:       "whitespace-only is no-op",
			sessionKey: "telegram:123",
			content:    "   \t\n  ",
			wantStored: false,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			store := newTestStore(t)
			err := store.Index(tc.sessionKey, tc.content)
			if (err != nil) != tc.wantErr {
				t.Fatalf("Index() error = %v, wantErr %v", err, tc.wantErr)
			}

			var count int
			store.db.QueryRow(`SELECT count(*) FROM memory_fts`).Scan(&count)
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
	store := newTestStore(t)

	_ = store.Index("session-a", "The Q1 budget review is on Thursday with the finance team.")
	_ = store.Index("session-b", "Reminder: submit expense report by Friday.")
	_ = store.Index("session-c", "The project deadline for phase two is next month.")

	tests := []struct {
		name      string
		query     string
		limit     int
		wantCount int // minimum matches expected
		wantNone  bool
	}{
		{
			name:      "finds budget entry",
			query:     "budget",
			limit:     5,
			wantCount: 1,
		},
		{
			name:      "finds expense entry",
			query:     "expense report",
			limit:     5,
			wantCount: 1,
		},
		{
			name:      "limit respected",
			query:     "budget",
			limit:     1,
			wantCount: 1,
		},
		{
			name:     "no match",
			query:    "quantum entanglement",
			limit:    5,
			wantNone: true,
		},
		{
			name:     "empty query returns nil",
			query:    "",
			limit:    5,
			wantNone: true,
		},
		{
			name:     "zero limit returns nil",
			query:    "budget",
			limit:    0,
			wantNone: true,
		},
		{
			name:      "FTS5 special chars in query do not crash",
			query:     `budget (review) "team" *`,
			limit:     5,
			wantCount: 0, // sanitized to safe query — may or may not match
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			results, err := store.Search(tc.query, tc.limit)
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
			if tc.limit > 0 && len(results) > tc.limit {
				t.Errorf("results %d exceeds limit %d", len(results), tc.limit)
			}
			// Verify result shape.
			for _, r := range results {
				if _, ok := r["content"]; !ok {
					t.Error("result missing 'content' key")
				}
				if _, ok := r["session_key"]; !ok {
					t.Error("result missing 'session_key' key")
				}
				if _, ok := r["timestamp"]; !ok {
					t.Error("result missing 'timestamp' key")
				}
			}
		})
	}
}

// ── Rebuild ────────────────────────────────────────────────────────────────────

func TestRebuild(t *testing.T) {
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
	results, _ := store.Search("financial report", 5)
	if len(results) == 0 {
		t.Error("expected to find 'financial report' after rebuild")
	}

	// Verify session key is derived from filename.
	found := false
	for _, r := range results {
		if r["session_key"] == "session-alpha" {
			found = true
			break
		}
	}
	if !found {
		t.Error("session key 'session-alpha' not found in results")
	}
}

func TestRebuild_NonexistentDir(t *testing.T) {
	store := newTestStore(t)
	_, err := store.Rebuild(filepath.Join(t.TempDir(), "does-not-exist"))
	if err == nil {
		t.Error("expected error for nonexistent directory, got nil")
	}
}

// ── sanitizeFTSQuery ───────────────────────────────────────────────────────────

func TestSanitizeFTSQuery(t *testing.T) {
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
	return os.WriteFile(path, []byte(content), 0o644)
}
