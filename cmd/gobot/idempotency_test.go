//nolint:testpackage // intentionally uses unexported helpers from main package
package main

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/app"
	agentctx "github.com/allthingscode/gobot/internal/context"
)

func TestGenerateIdempotencyKey(t *testing.T) {
	t.Parallel()
	// Should produce unique keys
	k1 := app.GenerateIdempotencyKey()
	k2 := app.GenerateIdempotencyKey()
	if k1 == k2 {
		t.Errorf("Generated identical keys: %s", k1)
	}
	// UUID v4 format is 36 chars.
	if len(k1) < 30 {
		t.Errorf("Expected uuid-like key, got %d chars: %s", len(k1), k1)
	}
}

// setupTestStore creates a temporary database for integration tests.
func setupTestStore(t *testing.T) (store *agentctx.IdempotencyStore, db *sql.DB, cleanup func()) {
	t.Helper()
	tmpDir := t.TempDir()
	dbPath := filepath.Join(tmpDir, "test.db")
	var err error
	db, err = sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}

	// Create idempotency_keys table with correct schema from internal/context/idempotency.go
	_, err = db.ExecContext(context.Background(), `
		CREATE TABLE IF NOT EXISTS idempotency_keys (
			key TEXT PRIMARY KEY,
			tool_name TEXT NOT NULL,
			params_hash TEXT NOT NULL,
			result TEXT NOT NULL,
			session_key TEXT NOT NULL,
			created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
		);
	`)
	if err != nil {
		t.Fatalf("create table: %v", err)
	}

	store = agentctx.NewIdempotencyStore(db, 24*time.Hour)
	cleanup = func() { _ = db.Close() }
	return store, db, cleanup
}

func TestIdempotencyCleanup(t *testing.T) {
	t.Parallel()
	// Integration test for the background cleanup loop.
	store, db, cleanup := setupTestStore(t)
	defer cleanup()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// 1. Store a key that will expire.
	err := store.Store(ctx, "expired-key", "test-tool", "hash1", "result", "session")
	if err != nil {
		t.Fatalf("store failed: %v", err)
	}

	// 2. Store a valid key.
	err = store.Store(ctx, "valid-key", "test-tool", "hash2", "result", "session")
	if err != nil {
		t.Fatalf("store failed: %v", err)
	}

	// 3. Manually backdate the first key to before the TTL (24h).
	// Use string format that SQLite definitely likes for comparisons.
	past := time.Now().Add(-25 * time.Hour).Format("2006-01-02 15:04:05")
	_, err = db.ExecContext(ctx, "UPDATE idempotency_keys SET created_at = ? WHERE key = 'expired-key'", past)
	if err != nil {
		t.Fatalf("update failed: %v", err)
	}

	// 4. Run cleanup once.
	cleaned, err := store.CleanupExpired(ctx)
	if err != nil {
		t.Fatalf("CleanupExpired: %v", err)
	}
	if cleaned != 1 {
		t.Errorf("CleanupExpired() = %d, want 1", cleaned)
	}

	// 5. Verify DB state.
	var count int
	_ = db.QueryRowContext(ctx, "SELECT COUNT(*) FROM idempotency_keys").Scan(&count)
	if count != 1 {
		t.Errorf("DB count = %d, want 1", count)
	}

	// 6. Test the periodic loop function (RunIdempotencyCleanup).
	go app.RunIdempotencyCleanup(ctx, store, 100*time.Millisecond)
	time.Sleep(200 * time.Millisecond)

	// Add another one and backdate it
	_ = store.Store(ctx, "expired-key-2", "test-tool", "hash3", "result", "session")
	_, _ = db.ExecContext(ctx, "UPDATE idempotency_keys SET created_at = ? WHERE key = 'expired-key-2'", past)

	time.Sleep(300 * time.Millisecond) // Wait for next tick

	_ = db.QueryRowContext(ctx, "SELECT COUNT(*) FROM idempotency_keys").Scan(&count)
	if count != 1 {
		t.Errorf("DB count after periodic loop = %d, want 1 (expired key should be gone)", count)
	}
}
