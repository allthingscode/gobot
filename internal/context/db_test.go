//nolint:testpackage // requires unexported DB internals for testing
package context

import (
	stdctx "context"
	"os"
	"path/filepath"
	"testing"
)

func TestOpenDB(t *testing.T) { //nolint:paralleltest // modifies global environment
	t.Run("creates directory and database", func(t *testing.T) {
		t.Parallel()
		tmpDir := t.TempDir()
		db, err := openDB(tmpDir)
		if err != nil {
			t.Fatalf("openDB: %v", err)
		}
		if db == nil {
			t.Fatal("expected non-nil database handle")
		}
		defer func() { _ = db.Close() }()

		dbPath := filepath.Join(tmpDir, "workspace", dbFileName)
		if _, err := os.Stat(dbPath); err != nil {
			t.Errorf("database file not created: %v", err)
		}

		var mode string
		if err := db.QueryRowContext(stdctx.Background(), "PRAGMA journal_mode").Scan(&mode); err != nil {
			t.Fatalf("query journal_mode: %v", err)
		}
		if mode != "wal" {
			t.Errorf("expected journal_mode WAL, got %q", mode)
		}
	})

	t.Run("handles existing directory", func(t *testing.T) {
		t.Parallel()
		tmpDir := t.TempDir()
		// Pre-create directory.
		_ = os.MkdirAll(filepath.Join(tmpDir, "workspace"), 0o755)

		db, err := openDB(tmpDir)
		if err != nil {
			t.Fatalf("openDB: %v", err)
		}
		_ = db.Close()
	})
}

func TestInitSchema(t *testing.T) { //nolint:paralleltest // modifies global environment
	t.Run("creates all required tables", func(t *testing.T) {
		t.Parallel()
		tmpDir := t.TempDir()
		db, err := openDB(tmpDir)
		if err != nil {
			t.Fatalf("openDB: %v", err)
		}
		defer func() { _ = db.Close() }()

		if err := initSchema(db); err != nil {
			t.Fatalf("initSchema: %v", err)
		}

		for _, table := range []string{"threads", "checkpoints"} {
			var name string
			err := db.QueryRowContext(
				stdctx.Background(),
				"SELECT name FROM sqlite_master WHERE type='table' AND name=?", table,
			).Scan(&name)
			if err != nil {
				t.Errorf("table %q not created: %v", table, err)
			}
		}
	})

	t.Run("is idempotent", func(t *testing.T) {
		t.Parallel()
		tmpDir := t.TempDir()
		db, _ := openDB(tmpDir)
		defer func() { _ = db.Close() }()

		_ = initSchema(db)
		if err := initSchema(db); err != nil {
			t.Errorf("second initSchema failed: %v", err)
		}
	})
}
