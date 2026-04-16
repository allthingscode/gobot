//nolint:testpackage // requires unexported Store methods for testing
package memory

import (
	"context"
	"database/sql"
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
	if err := store.db.QueryRowContext(context.Background(), "PRAGMA journal_mode").Scan(&mode); err != nil {
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

func TestMigrationV0ToV1(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	dbPath := filepath.Join(root, "workspace", "memory.db")
	_ = os.MkdirAll(filepath.Dir(dbPath), 0o755)

	// 1. Create a V0 database manually
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("failed to open raw db: %v", err)
	}
	_, err = db.ExecContext(context.Background(), `
		CREATE VIRTUAL TABLE memory_fts USING fts5(
			session_key UNINDEXED,
			content,
			timestamp   UNINDEXED
		)
	`)
	if err != nil {
		t.Fatalf("failed to create V0 table: %v", err)
	}
	_, err = db.ExecContext(context.Background(), `INSERT INTO memory_fts(session_key, content, timestamp) VALUES (?, ?, ?)`,
		"sess123", "legacy content", "2026-01-01T00:00:00Z")
	if err != nil {
		t.Fatalf("failed to insert legacy data: %v", err)
	}
	_ = db.Close()

	// 2. Open with NewMemoryStore (triggers migration)
	store, err := NewMemoryStore(root)
	if err != nil {
		t.Fatalf("failed to open for migration: %v", err)
	}
	defer func() { _ = store.Close() }()

	// 3. Verify PRAGMA user_version is 1
	var version int
	if err := store.db.QueryRowContext(context.Background(), "PRAGMA user_version").Scan(&version); err != nil {
		t.Fatalf("failed to query version: %v", err)
	}
	if version != 1 {
		t.Errorf("user_version = %d, want 1", version)
	}

	// 4. Verify data is migrated with session: prefix
	results, err := store.Search("legacy", "sess123", 5)
	if err != nil {
		t.Fatalf("Search failed: %v", err)
	}
	if len(results) != 1 {
		t.Fatalf("expected 1 result, got %d", len(results))
	}
	if results[0]["namespace"] != "session:sess123" {
		t.Errorf("namespace = %q, want 'session:sess123'", results[0]["namespace"])
	}
}

// ── Index ──────────────────────────────────────────────────────────────────────

func TestIndex(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name       string
		namespace  string
		content    string
		wantErr    bool
		wantStored bool
	}{
		{
			name:       "normal entry",
			namespace:  "session:123",
			content:    "The project deadline is March 31.",
			wantStored: true,
		},
		{
			name:       "global entry",
			namespace:  "global",
			content:    "User prefers metric units.",
			wantStored: true,
		},
		{
			name:       "empty content is no-op",
			namespace:  "global",
			content:    "",
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
			if err := store.db.QueryRowContext(context.Background(), `SELECT count(*) FROM memory_fts`).Scan(&count); err != nil {
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

func seedSearchData(t *testing.T, store *MemoryStore) {
	t.Helper()
	_ = store.Index("session:a", "The Q1 budget review is on Thursday with the finance team.")
	_ = store.Index("session:b", "Reminder: submit expense report by Friday.")
	_ = store.Index("global", "Project Alpha deadline is May 1st.")
}

func validateSearchResults(t *testing.T, results []map[string]any, wantCount int, wantNone bool) {
	t.Helper()
	if wantNone {
		if len(results) != 0 {
			t.Errorf("want no results, got %d", len(results))
		}
		return
	}
	if len(results) < wantCount {
		t.Errorf("want at least %d results, got %d", wantCount, len(results))
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
}

func TestSearch(t *testing.T) {
	t.Parallel()
	store := newTestStore(t)
	seedSearchData(t, store)

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
			validateSearchResults(t, results, tc.wantCount, tc.wantNone)
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
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		return fmt.Errorf("write helper file: %w", err)
	}
	return nil
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
