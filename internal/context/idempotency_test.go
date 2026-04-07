package context_test

import (
	"database/sql"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/context"

	_ "modernc.org/sqlite"
)

// setupTestStore creates a temporary database with the idempotency_keys table
// and returns an IdempotencyStore with a 1-hour TTL for testing.
func setupTestStore(t *testing.T) (*context.IdempotencyStore, *sql.DB, func()) {
	t.Helper()

	// Create temporary database.
	tmpDir := t.TempDir()
	dbPath := filepath.Join(tmpDir, "test.db")
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}

	// Create idempotency_keys table.
	_, err = db.Exec(`
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

	_, err = db.Exec(`
		CREATE INDEX IF NOT EXISTS idx_idempotency_session
		ON idempotency_keys(session_key)
	`)
	if err != nil {
		t.Fatalf("create index: %v", err)
	}

	_, err = db.Exec(`
		CREATE INDEX IF NOT EXISTS idx_idempotency_created
		ON idempotency_keys(created_at)
	`)
	if err != nil {
		t.Fatalf("create index: %v", err)
	}

	store := context.NewIdempotencyStore(db, 1*time.Hour)
	cleanup := func() {
		db.Close()
		os.RemoveAll(tmpDir)
	}

	return store, db, cleanup
}

func TestIdempotencyStore_Check_Miss(t *testing.T) {
	t.Parallel()
	store, _, cleanup := setupTestStore(t)
	defer cleanup()

	result, err := store.Check("nonexistent-key", "send_email", "abc123")
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

	// Store a result.
	paramsHash, err := context.HashParams(map[string]any{"to": "test@example.com", "subject": "Test"})
	if err != nil {
		t.Fatalf("HashParams() error: %v", err)
	}

	err = store.Store("idem-key-1", "send_email", paramsHash, "Email sent", "session-1")
	if err != nil {
		t.Fatalf("Store() error: %v", err)
	}

	// Check should return the cached result.
	result, err := store.Check("idem-key-1", "send_email", paramsHash)
	if err != nil {
		t.Fatalf("Check() error: %v", err)
	}
	if !result.Found {
		t.Errorf("Check() returned Found=false for existing key")
	}
	if result.CachedResult != "Email sent" {
		t.Errorf("CachedResult = %q, want %q", result.CachedResult, "Email sent")
	}
	if result.HashMismatch {
		t.Errorf("Check() incorrectly reported HashMismatch")
	}
}

func TestIdempotencyStore_Check_Hash_Mismatch(t *testing.T) {
	t.Parallel()
	store, _, cleanup := setupTestStore(t)
	defer cleanup()

	// Store with one params hash.
	hash1, _ := context.HashParams(map[string]any{"subject": "Original"})
	err := store.Store("idem-key-2", "send_email", hash1, "Original result", "session-1")
	if err != nil {
		t.Fatalf("Store() error: %v", err)
	}

	// Check with different params hash should fail.
	hash2, _ := context.HashParams(map[string]any{"subject": "Modified"})
	result, err := store.Check("idem-key-2", "send_email", hash2)
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
	_, err := db.Exec(`
		INSERT INTO idempotency_keys (key, tool_name, params_hash, result, session_key, created_at)
		VALUES (?, ?, ?, ?, ?, ?)
	`, "expired-key", "send_email", "hash1", "Old result", "session-1", oldTime)
	if err != nil {
		t.Fatalf("insert expired record: %v", err)
	}

	// Insert a recent record (not expired).
	_, err = db.Exec(`
		INSERT INTO idempotency_keys (key, tool_name, params_hash, result, session_key, created_at)
		VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
	`, "fresh-key", "send_email", "hash2", "Fresh result", "session-2")
	if err != nil {
		t.Fatalf("insert fresh record: %v", err)
	}

	// Cleanup should remove only the expired record.
	cleaned, err := store.CleanupExpired()
	if err != nil {
		t.Fatalf("CleanupExpired() error: %v", err)
	}
	if cleaned != 1 {
		t.Errorf("CleanupExpired() removed %d records, want 1", cleaned)
	}

	// Verify fresh record still exists.
	var count int
	err = db.QueryRow("SELECT COUNT(*) FROM idempotency_keys WHERE key = ?", "fresh-key").Scan(&count)
	if err != nil {
		t.Fatalf("query fresh record: %v", err)
	}
	if count != 1 {
		t.Errorf("Fresh record was incorrectly removed")
	}

	// Verify expired record was removed.
	err = db.QueryRow("SELECT COUNT(*) FROM idempotency_keys WHERE key = ?", "expired-key").Scan(&count)
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
	paramsHash, _ := context.HashParams(map[string]any{"subject": "Test"})
	_, err := db.Exec(`
		INSERT INTO idempotency_keys (key, tool_name, params_hash, result, session_key, created_at)
		VALUES (?, ?, ?, ?, ?, ?)
	`, "expired-key", "send_email", paramsHash, "Old result", "session-1", oldTime)
	if err != nil {
		t.Fatalf("insert expired record: %v", err)
	}

	// Check should treat expired record as not found.
	result, err := store.Check("expired-key", "send_email", paramsHash)
	if err != nil {
		t.Fatalf("Check() error: %v", err)
	}
	if result.Found {
		t.Errorf("Check() should not find expired key")
	}
}

func TestIdempotencyStore_Concurrent_Access(t *testing.T) {
	t.Parallel()
	store, _, cleanup := setupTestStore(t)
	defer cleanup()

	done := make(chan bool, 10)

	// Spawn 10 goroutines that concurrently store and check.
	for i := 0; i < 10; i++ {
		go func(_ int) {
			key := "concurrent-key"

			// Store might fail due to primary key collision, which is expected.
			hash1, _ := context.HashParams(map[string]any{"test": "data"})
			_ = store.Store(key, "send_email", hash1, "Result", "session-1")

			// All goroutines should be able to check.
			_, _ = store.Check(key, "send_email", hash1)
			done <- true
		}(i)
	}

	// Wait for all goroutines.
	for i := 0; i < 10; i++ {
		<-done
	}
}

func TestHashParams_Deterministic(t *testing.T) {
	t.Parallel()
	params := map[string]any{
		"to":      "test@example.com",
		"subject": "Test Subject",
		"body":    "Test body",
	}

	hash1, err := context.HashParams(params)
	if err != nil {
		t.Fatalf("HashParams() error: %v", err)
	}

	hash2, err := context.HashParams(params)
	if err != nil {
		t.Fatalf("HashParams() error: %v", err)
	}

	if hash1 != hash2 {
		t.Errorf("HashParams() is not deterministic: %q != %q", hash1, hash2)
	}
}

func TestHashParams_Order_Independent(t *testing.T) {
	t.Parallel()
	params1 := map[string]any{"a": 1, "b": 2, "c": 3}
	params2 := map[string]any{"c": 3, "a": 1, "b": 2}

	hash1, err := context.HashParams(params1)
	if err != nil {
		t.Fatalf("HashParams() error: %v", err)
	}

	hash2, err := context.HashParams(params2)
	if err != nil {
		t.Fatalf("HashParams() error: %v", err)
	}

	if hash1 != hash2 {
		t.Errorf("HashParams() should be order independent: %q != %q", hash1, hash2)
	}
}

func TestHashParams_Different_Values(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name   string
		params map[string]any
	}{
		{
			name:   "empty_params",
			params: map[string]any{},
		},
		{
			name:   "simple_types",
			params: map[string]any{"str": "hello", "num": 42, "bool": true},
		},
		{
			name:   "nested_map",
			params: map[string]any{"nested": map[string]any{"key": "value"}},
		},
		{
			name:   "array_value",
			params: map[string]any{"items": []string{"a", "b", "c"}},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
		t.Parallel()
			hash, err := context.HashParams(tt.params)
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
