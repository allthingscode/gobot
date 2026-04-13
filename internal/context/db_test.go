//nolint:testpackage // requires unexported DB internals for testing
package context

import (
	"os"
	"path/filepath"
	"testing"
)

func TestOpenDB(t *testing.T) {
	t.Parallel()
	t.Run("creates workspace dir and db file", func(t *testing.T) {
		t.Parallel()
		root := t.TempDir()
		db, err := openDB(root)
		if err != nil {
			t.Fatalf("openDB: %v", err)
		}
		defer func() { _ = db.Close() }()

		expected := filepath.Join(root, "workspace", dbFileName)
		if _, err := os.Stat(expected); os.IsNotExist(err) {
			t.Errorf("expected db file at %s, not found", expected)
		}
	})

	t.Run("WAL mode enabled", func(t *testing.T) {
		t.Parallel()
		root := t.TempDir()
		db, err := openDB(root)
		if err != nil {
			t.Fatalf("openDB: %v", err)
		}
		defer func() { _ = db.Close() }()

		var mode string
		if err := db.QueryRow("PRAGMA journal_mode").Scan(&mode); err != nil {
			t.Fatalf("query journal_mode: %v", err)
		}
		if mode != "wal" {
			t.Errorf("expected WAL mode, got %q", mode)
		}
	})

	t.Run("returns error for invalid path", func(t *testing.T) {
		t.Parallel()
		// Use a path that cannot be created (file in place of dir).
		root := t.TempDir()
		blocker := filepath.Join(root, "workspace")
		// Create a regular file where the directory should be.
		if err := os.WriteFile(blocker, []byte("x"), 0o600); err != nil {
			t.Fatalf("setup: %v", err)
		}
		_, err := openDB(root)
		if err == nil {
			t.Error("expected error when workspace path is a file, got nil")
		}
	})
}

func TestInitSchema(t *testing.T) {
	t.Parallel()
	t.Run("creates threads and checkpoints tables", func(t *testing.T) {
		t.Parallel()
		root := t.TempDir()
		db, err := openDB(root)
		if err != nil {
			t.Fatalf("openDB: %v", err)
		}
		defer func() { _ = db.Close() }()

		if err := initSchema(db); err != nil {
			t.Fatalf("initSchema: %v", err)
		}

		for _, table := range []string{"threads", "checkpoints"} {
			var name string
			err := db.QueryRow(
				"SELECT name FROM sqlite_master WHERE type='table' AND name=?", table,
			).Scan(&name)
			if err != nil {
				t.Errorf("table %q not found: %v", table, err)
			}
		}
	})

	t.Run("idempotent — calling twice does not error", func(t *testing.T) {
		t.Parallel()
		root := t.TempDir()
		db, err := openDB(root)
		if err != nil {
			t.Fatalf("openDB: %v", err)
		}
		defer func() { _ = db.Close() }()

		if err := initSchema(db); err != nil {
			t.Fatalf("first initSchema: %v", err)
		}
		if err := initSchema(db); err != nil {
			t.Errorf("second initSchema: %v", err)
		}
	})
}
