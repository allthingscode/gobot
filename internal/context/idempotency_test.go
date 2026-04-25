//nolint:testpackage // requires unexported idempotency internals for testing
package context

import (
	stdctx "context"
	"database/sql"
	"path/filepath"
	"testing"
	"time"
)

// setupTestStore creates a clean in-memory IdempotencyStore for testing.
func setupTestStore(t *testing.T) (*IdempotencyStore, *sql.DB, func()) {
	t.Helper()
	tmp := t.TempDir()
	db, err := sql.Open("sqlite", filepath.Join(tmp, "idemp.db"))
	if err != nil {
		t.Fatalf("open db: %v", err)
	}

	// Create idempotency_keys table.
	_, err = db.ExecContext(stdctx.Background(), `
		CREATE TABLE IF NOT EXISTS idempotency_keys (
			key         TEXT PRIMARY KEY,
			tool_name   TEXT NOT NULL,
			params_hash TEXT NOT NULL,
			result      TEXT,
			session_key TEXT,
			created_at  DATETIME DEFAULT CURRENT_TIMESTAMP
		)
	`)
	if err != nil {
		t.Fatalf("create table: %v", err)
	}

	_, err = db.ExecContext(stdctx.Background(), `
		CREATE INDEX IF NOT EXISTS idx_idempotency_session
		ON idempotency_keys(session_key)
	`)
	if err != nil {
		t.Fatalf("create index session: %v", err)
	}

	_, err = db.ExecContext(stdctx.Background(), `
		CREATE INDEX IF NOT EXISTS idx_idempotency_created
		ON idempotency_keys(created_at)
	`)
	if err != nil {
		t.Fatalf("create index created: %v", err)
	}

	store := NewIdempotencyStore(db, 1*time.Hour)
	return store, db, func() { _ = db.Close() }
}

func TestIdempotencyStore_Check_Miss(t *testing.T) {
	t.Parallel()
	store, _, cleanup := setupTestStore(t)
	defer cleanup()

	result, err := store.Check(stdctx.Background(), "nonexistent-key", "send_email", "abc123")
	if err != nil {
		t.Fatalf("Check() error: %v", err)
	}
	if result.Found {
		t.Errorf("Check() returned Found=true for nonexistent key")
	}
}

func TestIdempotencyStore_Store_And_Check_Hit(t *testing.T) {
	t.Parallel()
	store, _, cleanup := setupTestStore(t)
	defer cleanup()

	paramsHash, err := HashParams(map[string]any{"subject": "Test Email"})
	if err != nil {
		t.Fatalf("HashParams() error: %v", err)
	}

	// Initial store should succeed.
	err = store.Store(stdctx.Background(), "idem-key-1", "send_email", paramsHash, "Email sent", "session-1")
	if err != nil {
		t.Fatalf("Store() error: %v", err)
	}

	// Check should return the cached result.
	result, err := store.Check(stdctx.Background(), "idem-key-1", "send_email", paramsHash)
	if err != nil {
		t.Fatalf("Check() error: %v", err)
	}
	if !result.Found {
		t.Errorf("Check() returned Found=false for existing key")
	}
	if result.CachedResult != "Email sent" {
		t.Errorf("CachedResult = %q, want %q", result.CachedResult, "Email sent")
	}
}

func TestIdempotencyStore_Check_Hash_Mismatch(t *testing.T) {
	t.Parallel()
	store, _, cleanup := setupTestStore(t)
	defer cleanup()

	// Store with one params hash.
	hash1, _ := HashParams(map[string]any{"subject": "Original"})
	err := store.Store(stdctx.Background(), "idem-key-2", "send_email", hash1, "Original result", "session-1")
	if err != nil {
		t.Fatalf("Store() error: %v", err)
	}

	// Check with different params hash should fail.
	hash2, _ := HashParams(map[string]any{"subject": "Modified"})
	result, err := store.Check(stdctx.Background(), "idem-key-2", "send_email", hash2)
	if err == nil {
		t.Errorf("Check() should return error for hash mismatch")
	}
	if !result.HashMismatch {
		t.Errorf("Check() should report HashMismatch")
	}
}

func TestIdempotencyStore_Cleanup_Expired(t *testing.T) {
	t.Parallel()
	store, db, cleanup := setupTestStore(t)
	defer cleanup()

	// Insert a record with old timestamp (expired).
	oldTime := time.Now().Add(-2 * time.Hour).Format("2006-01-02 15:04:05")
	_, err := db.ExecContext(stdctx.Background(), `
		INSERT INTO idempotency_keys (key, tool_name, params_hash, result, session_key, created_at)
		VALUES (?, ?, ?, ?, ?, ?)
	`, "expired-key", "send_email", "hash1", "Old result", "session-1", oldTime)
	if err != nil {
		t.Fatalf("insert expired record: %v", err)
	}

	// Insert a recent record (not expired).
	_, err = db.ExecContext(stdctx.Background(), `
		INSERT INTO idempotency_keys (key, tool_name, params_hash, result, session_key, created_at)
		VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
	`, "fresh-key", "send_email", "hash2", "Fresh result", "session-2")
	if err != nil {
		t.Fatalf("insert fresh record: %v", err)
	}

	// Cleanup should remove only the expired record.
	cleaned, err := store.CleanupExpired(stdctx.Background())
	if err != nil {
		t.Fatalf("CleanupExpired() error: %v", err)
	}
	if cleaned != 1 {
		t.Errorf("CleanupExpired() removed %d records, want 1", cleaned)
	}

	// Verify fresh record still exists.
	var count int
	err = db.QueryRowContext(stdctx.Background(), "SELECT COUNT(*) FROM idempotency_keys WHERE key = ?", "fresh-key").Scan(&count)
	if err != nil {
		t.Fatalf("query fresh record: %v", err)
	}
	if count != 1 {
		t.Errorf("Fresh record was incorrectly removed")
	}

	// Verify expired record was removed.
	err = db.QueryRowContext(stdctx.Background(), "SELECT COUNT(*) FROM idempotency_keys WHERE key = ?", "expired-key").Scan(&count)
	if err != nil {
		t.Fatalf("query expired record: %v", err)
	}
	if count != 0 {
		t.Errorf("Expired record was not removed")
	}
}

func TestIdempotencyStore_TTL_Expiry_On_Check(t *testing.T) {
	t.Parallel()
	store, db, cleanup := setupTestStore(t)
	defer cleanup()

	// Insert a record with timestamp older than TTL (1 hour in test setup).
	oldTime := time.Now().Add(-2 * time.Hour).Format("2006-01-02 15:04:05")
	paramsHash, _ := HashParams(map[string]any{"subject": "Test"})
	_, err := db.ExecContext(stdctx.Background(), `
		INSERT INTO idempotency_keys (key, tool_name, params_hash, result, session_key, created_at)
		VALUES (?, ?, ?, ?, ?, ?)
	`, "expired-key", "send_email", paramsHash, "Old result", "session-1", oldTime)
	if err != nil {
		t.Fatalf("insert expired record: %v", err)
	}

	// Check should treat expired record as not found.
	result, err := store.Check(stdctx.Background(), "expired-key", "send_email", paramsHash)
	if err != nil {
		t.Fatalf("Check() error: %v", err)
	}
	if result.Found {
		t.Errorf("Check() should not find expired key")
	}

	// Verify it was actually deleted from DB.
	var count int
	_ = db.QueryRowContext(stdctx.Background(), "SELECT COUNT(*) FROM idempotency_keys WHERE key = ?", "expired-key").Scan(&count)
	if count != 0 {
		t.Error("Expired key was not deleted after Check()")
	}
}

func TestIdempotencyStore_Concurrent_Access(t *testing.T) {
	t.Parallel()
	store, _, cleanup := setupTestStore(t)
	defer cleanup()

	const workers = 10
	done := make(chan bool, workers)

	for i := 0; i < workers; i++ {
		go func(_ int) {
			key := "concurrent-key"

			// Store might fail due to primary key collision, which is expected.
			hash1, _ := HashParams(map[string]any{"test": "data"})
			_ = store.Store(stdctx.Background(), key, "send_email", hash1, "Result", "session-1")

			// All goroutines should be able to check.
			_, _ = store.Check(stdctx.Background(), key, "send_email", hash1)
			done <- true
		}(i)
	}

	// Wait for all goroutines.
	for i := 0; i < workers; i++ {
		<-done
	}
}

func TestHashParams(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name   string
		params map[string]any
	}{
		{"nil map", nil},
		{"empty map", map[string]any{}},
		{"simple map", map[string]any{"foo": "bar", "num": 123}},
		{"nested map", map[string]any{"foo": map[string]any{"bar": "baz"}}},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			hash, err := HashParams(tt.params)
			if err != nil {
				t.Fatalf("HashParams() error: %v", err)
			}
			if hash == "" {
				t.Errorf("HashParams() returned empty hash")
			}
			if len(hash) != 64 {
				t.Errorf("HashParams() returned hash of length %d, want 64", len(hash))
			}
		})
	}
}
