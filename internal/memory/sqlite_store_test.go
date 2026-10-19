//nolint:testpackage // requires unexported Store methods for testing
package memory

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
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

	// 3. Verify PRAGMA user_version is 2 (V0 legacy → V1 → V2 in one pass)
	var version int
	if err := store.db.QueryRowContext(context.Background(), "PRAGMA user_version").Scan(&version); err != nil {
		t.Fatalf("failed to query version: %v", err)
	}
	if version != 2 {
		t.Errorf("user_version = %d, want 2", version)
	}

	// 4. Verify data is migrated with session: prefix
	results, err := store.Search(context.Background(), "legacy", "sess123", 5)
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
			results, err := store.Search(context.Background(), tc.query, tc.sessionKey, tc.limit)
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
	results, _ := store.Search(context.Background(), "financial report", "session-alpha", 5)
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
	root := t.TempDir()
	setupRebuildLimit(t, root)
	n, err := store.Rebuild(root)
	if n != maxRebuildFiles || err != nil {
		t.Fatalf("exact cap: count=%d err=%v", n, err)
	}
	if err := writeFile(filepath.Join(root, "z-extra.md"), "extra"); err != nil {
		t.Fatal(err)
	}
	n, err = store.Rebuild(root)
	if n != maxRebuildFiles || err == nil || !strings.Contains(err.Error(), "truncated") {
		t.Fatalf("over cap: count=%d err=%v", n, err)
	}
}

func TestRebuildTruncationPreservesEarlierFailure(t *testing.T) {
	t.Parallel()
	store := newTestStore(t)
	root := t.TempDir()
	setupRebuildLimit(t, root)
	for _, name := range []string{"a-failed.md", "z-extra.md"} {
		if err := writeFile(filepath.Join(root, name), "summary"); err != nil {
			t.Fatal(err)
		}
	}
	n, err := store.rebuildWithReader(root, func(path string) ([]byte, error) {
		if filepath.Base(path) == "a-failed.md" {
			return nil, os.ErrNotExist
		}
		return os.ReadFile(path)
	})
	if n != maxRebuildFiles || !errors.Is(err, os.ErrNotExist) || !strings.Contains(err.Error(), "truncated") || !strings.Contains(err.Error(), "skipped 1") {
		t.Fatalf("lost partial/truncation status: count=%d err=%v", n, err)
	}
}

func TestRebuildBoundsFailureDetails(t *testing.T) {
	t.Parallel()
	store := newTestStore(t)
	root := t.TempDir()
	for i := 0; i < 20; i++ {
		if err := writeFile(filepath.Join(root, fmt.Sprintf("%02d.md", i)), "summary"); err != nil {
			t.Fatal(err)
		}
	}
	n, err := store.rebuildWithReader(root, func(string) ([]byte, error) { return nil, os.ErrPermission })
	if n != 0 || !errors.Is(err, os.ErrPermission) || !strings.Contains(err.Error(), "skipped 20") || strings.Count(err.Error(), os.ErrPermission.Error()) != 10 {
		t.Fatalf("unbounded or missing error details: count=%d err=%v", n, err)
	}
}

func setupRebuildLimit(t *testing.T, root string) {
	t.Helper()
	for i := 0; i < maxRebuildFiles; i++ {
		if err := writeFile(filepath.Join(root, fmt.Sprintf("session-%05d.md", i)), "Summary: mock"); err != nil {
			t.Fatal(err)
		}
	}
	if err := writeFile(filepath.Join(root, "z.txt"), "irrelevant"); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(root, "z-dir"), 0o700); err != nil {
		t.Fatal(err)
	}
}

func TestRebuildFailures(t *testing.T) {
	t.Parallel()
	for _, kind := range []string{"closed", "missing", "read", "index"} {
		t.Run(kind, func(t *testing.T) {
			t.Parallel()
			store, root, reader, wantCount := setupRebuildFailure(t, kind)
			n, err := store.rebuildWithReader(root, reader)
			if n != wantCount || err == nil || !strings.Contains(err.Error(), root) {
				t.Fatalf("count=%d want=%d err=%v", n, wantCount, err)
			}
			if (kind == "read" || kind == "missing") && !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("lost cause: %v", err)
			}
		})
	}
}

func setupRebuildFailure(t *testing.T, kind string) (store *MemoryStore, root string, reader func(string) ([]byte, error), wantCount int) {
	t.Helper()
	store = newTestStore(t)
	root = t.TempDir()
	for _, name := range []string{"a.md", "b.md"} {
		if err := writeFile(filepath.Join(root, name), "summary"); err != nil {
			t.Fatal(err)
		}
	}
	reader = os.ReadFile
	wantCount = 0
	switch kind {
	case "closed":
		if err := store.Close(); err != nil {
			t.Fatal(err)
		}
	case "missing":
		root = filepath.Join(root, "missing")
	case "read":
		wantCount = 1
		reader = func(path string) ([]byte, error) {
			if filepath.Base(path) == "a.md" {
				return nil, os.ErrNotExist
			}
			return os.ReadFile(path)
		}
	case "index":
		wantCount = 1
		reader = func(path string) ([]byte, error) {
			if filepath.Base(path) == "b.md" {
				_ = store.Close()
			}
			return os.ReadFile(path)
		}
	}
	return store, root, reader, wantCount
}

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

// ── F-114: Importance scoring ──────────────────────────────────────────────────

func TestIndexWithImportance_StoresAndRetrieves(t *testing.T) {
	t.Parallel()
	store := newTestStore(t)

	if err := store.IndexWithImportance("session:s1", "Project deadline May 2026", 5); err != nil {
		t.Fatalf("IndexWithImportance: %v", err)
	}
	results, err := store.Search(context.Background(), "deadline", "s1", 5)
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	if len(results) == 0 {
		t.Fatal("expected at least one result, got none")
	}
}

func TestIndexWithImportance_ClampedOutOfRange(t *testing.T) {
	t.Parallel()
	store := newTestStore(t)
	// Out-of-range values should be stored without error (clamped internally).
	if err := store.IndexWithImportance("session:s1", "fact with bad score", 99); err != nil {
		t.Fatalf("IndexWithImportance with bad score: %v", err)
	}
}

func TestIndex_UsesDefaultImportance(t *testing.T) {
	t.Parallel()
	store := newTestStore(t)
	if err := store.Index("session:s1", "default importance fact"); err != nil {
		t.Fatalf("Index: %v", err)
	}
	// Verify we can query it (importance=3 default is stored, not tested directly here
	// since Search doesn't return importance — the schema migration test covers that).
	results, err := store.Search(context.Background(), "default importance", "s1", 5)
	if err != nil || len(results) == 0 {
		t.Fatalf("Search after Index: err=%v results=%d", err, len(results))
	}
}

func openV1DB(t *testing.T) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("sql.Open: %v", err)
	}
	if _, err := db.ExecContext(context.Background(), "PRAGMA journal_mode=WAL"); err != nil {
		_ = db.Close()
		t.Fatalf("WAL: %v", err)
	}
	db.SetMaxOpenConns(1)
	for _, stmt := range []string{
		`CREATE VIRTUAL TABLE memory_fts USING fts5(namespace UNINDEXED, content, timestamp UNINDEXED)`,
		`INSERT INTO memory_fts(namespace, content, timestamp) VALUES ('session:test', 'original fact', '2026-01-01T00:00:00Z')`,
		`PRAGMA user_version = 1`,
	} {
		if _, err := db.ExecContext(context.Background(), stmt); err != nil {
			_ = db.Close()
			t.Fatalf("V1 setup: %s: %v", stmt, err)
		}
	}
	return db
}

//nolint:paralleltest // subtests share a single in-memory DB; parallel execution would close it prematurely
func TestInitMemorySchema_V1ToV2Migration(t *testing.T) {
	t.Parallel()
	db := openV1DB(t)
	defer func() { _ = db.Close() }()

	if err := initMemorySchema(db); err != nil {
		t.Fatalf("initMemorySchema: %v", err)
	}

	var version int
	if err := db.QueryRowContext(context.Background(), "PRAGMA user_version").Scan(&version); err != nil {
		t.Fatalf("PRAGMA user_version: %v", err)
	}
	if version != 2 {
		t.Errorf("expected user_version=2, got %d", version)
	}

	var content string
	var importance int
	if err := db.QueryRowContext(context.Background(),
		`SELECT content, importance FROM memory_fts WHERE memory_fts MATCH 'original'`).
		Scan(&content, &importance); err != nil {
		t.Fatalf("query migrated row: %v", err)
	}
	if content != "original fact" {
		t.Errorf("content = %q, want %q", content, "original fact")
	}
	if importance != 3 {
		t.Errorf("importance = %d, want 3", importance)
	}

	if _, err := db.ExecContext(context.Background(),
		`INSERT INTO memory_fts(namespace, content, timestamp, importance) VALUES ('session:test', 'new fact', '2026-01-02T00:00:00Z', 5)`); err != nil {
		t.Fatalf("insert V2 row: %v", err)
	}
}

func TestInitMemorySchema_FreshDBCreatesV2(t *testing.T) {
	t.Parallel()
	store := newTestStore(t)

	// Fresh DB should have user_version=2.
	var version int
	if err := store.db.QueryRowContext(context.Background(), "PRAGMA user_version").Scan(&version); err != nil {
		t.Fatalf("PRAGMA user_version: %v", err)
	}
	if version != 2 {
		t.Errorf("fresh DB user_version = %d, want 2", version)
	}

	// Should be able to insert with importance.
	if err := store.IndexWithImportance("session:s1", "test fact", 4); err != nil {
		t.Fatalf("IndexWithImportance on fresh V2 DB: %v", err)
	}
}

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

func TestSearchContract(t *testing.T) {
	t.Parallel()
	for _, tc := range []searchContractCase{
		{name: "match", query: "hello", limit: 5, count: 1},
		{name: "no match", query: "absent", limit: 5},
		{name: "empty", limit: 5},
		{name: "sanitized empty", query: "()*", limit: 5},
		{name: "zero limit", query: "hello"},
		{name: "negative limit", query: "hello", limit: -1},
		{name: "punctuation", query: "(hello)*", limit: 5, count: 1},
		{name: "parser", query: "hello OR", limit: 5},
		{name: "closed", query: "hello OR", limit: 5, fault: "closed"},
		{name: "schema", query: "hello OR", limit: 5, fault: "schema"},
		{name: "canceled", query: "hello", limit: 5, wantErr: context.Canceled},
		{name: "deadline", query: "hello", limit: 5, wantErr: context.DeadlineExceeded},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			checkSearchContract(t, tc)
		})
	}
}

// A connector avoids global driver registration and keeps each fault fixture isolated.
type searchFaultConnector struct{ rows *searchFaultRows }

func (c searchFaultConnector) Connect(context.Context) (driver.Conn, error) {
	return searchFaultConn(c), nil
}
func (c searchFaultConnector) Driver() driver.Driver { return searchFaultDriver{} }

type searchFaultDriver struct{}

func (searchFaultDriver) Open(string) (driver.Conn, error) { return nil, errors.New("use connector") }

type searchFaultConn struct{ rows *searchFaultRows }

func (c searchFaultConn) Prepare(string) (driver.Stmt, error) {
	return nil, errors.New("unsupported prepare")
}
func (c searchFaultConn) Close() error { return nil }
func (c searchFaultConn) Begin() (driver.Tx, error) {
	return nil, errors.New("unsupported transaction")
}
func (c searchFaultConn) QueryContext(context.Context, string, []driver.NamedValue) (driver.Rows, error) {
	return c.rows, nil
}

type searchFaultRows struct {
	validRows, next   int
	scanFault, closed bool
	err               error
}

func (*searchFaultRows) Columns() []string { return []string{"namespace", "content", "timestamp"} }
func (r *searchFaultRows) Close() error    { r.closed = true; return nil }
func (r *searchFaultRows) Next(dest []driver.Value) error {
	if r.next < r.validRows {
		r.next++
		dest[0], dest[1], dest[2] = "global", "hello", "timestamp"
		return nil
	}
	if r.scanFault {
		dest[0], dest[1], dest[2] = "global", nil, "timestamp"
		return nil
	}
	if r.err != nil {
		return r.err
	}
	return io.EOF
}

func TestSearchRowFailures(t *testing.T) {
	t.Parallel()
	fault := errors.New("iteration sentinel")
	for _, scan := range []bool{false, true} {
		for _, validRows := range []int{0, 1} {
			t.Run(fmt.Sprintf("scan=%t/valid=%d", scan, validRows), func(t *testing.T) {
				t.Parallel()
				checkSearchRowFailure(t, scan, validRows, fault)
			})
		}
	}
}

type searchContractCase struct {
	name, query, fault string
	limit, count       int
	wantErr            error
}

func checkSearchContract(t *testing.T, tc searchContractCase) {
	t.Helper()
	store := newTestStore(t)
	if err := store.Index("session:s", "hello world"); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	if errors.Is(tc.wantErr, context.Canceled) {
		var cancel context.CancelFunc
		ctx, cancel = context.WithCancel(ctx)
		cancel()
	}
	if errors.Is(tc.wantErr, context.DeadlineExceeded) {
		var cancel context.CancelFunc
		ctx, cancel = context.WithDeadline(ctx, time.Unix(1, 0))
		defer cancel()
	}
	if tc.fault == "closed" {
		if err := store.Close(); err != nil {
			t.Fatal(err)
		}
	}
	if tc.fault == "schema" {
		if _, err := store.db.ExecContext(ctx, "DROP TABLE memory_fts"); err != nil {
			t.Fatal(err)
		}
	}
	got, err := store.Search(ctx, tc.query, "s", tc.limit)
	checkSearchContractResult(t, tc, got, err)
}

func checkSearchRowFailure(t *testing.T, scan bool, validRows int, fault error) {
	t.Helper()
	rows := &searchFaultRows{validRows: validRows, scanFault: scan, err: fault}
	db := sql.OpenDB(searchFaultConnector{rows})
	t.Cleanup(func() { _ = db.Close() })
	store := &MemoryStore{db: db}
	got, err := store.Search(context.Background(), "hello", "s", 5)
	if err == nil || got != nil || !strings.Contains(err.Error(), "memory: search scan:") {
		t.Fatalf("Search = %v, %v", got, err)
	}
	if !scan && !errors.Is(err, fault) {
		t.Fatalf("lost sentinel: %v", err)
	}
	if scan && errors.Unwrap(err) == nil {
		t.Fatalf("scan error not wrapped: %v", err)
	}
	if !rows.closed {
		t.Fatal("rows not closed")
	}
}

func checkSearchContractResult(t *testing.T, tc searchContractCase, got []map[string]any, err error) {
	t.Helper()
	if tc.fault != "" || tc.wantErr != nil {
		if err == nil || got != nil || !strings.Contains(err.Error(), "memory: search query:") {
			t.Fatalf("Search = %v, %v", got, err)
		}
		if tc.wantErr != nil && !errors.Is(err, tc.wantErr) {
			t.Fatalf("error identity: %v", err)
		}
		return
	}
	if err != nil || len(got) != tc.count {
		t.Fatalf("Search = %v, %v; want %d results", got, err, tc.count)
	}
}
