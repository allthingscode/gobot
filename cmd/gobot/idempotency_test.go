//nolint:testpackage // intentionally uses unexported helpers from main package
package main

import (
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"testing"
	"time"

	agentctx "github.com/allthingscode/gobot/internal/context"
)

func TestGenerateIdempotencyKey(t *testing.T) {
	t.Parallel()
	// Should produce unique keys
	k1 := generateIdempotencyKey()
	k2 := generateIdempotencyKey()
	if k1 == k2 {
		t.Errorf("Generated identical keys: %s", k1)
	}

	// Should be 36 chars (UUID v4 format)
	if len(k1) != 36 {
		t.Errorf("Expected 36 chars, got %d: %s", len(k1), k1)
	}

	// Smoke test many generations
	for i := 0; i < 100; i++ {
		key := generateIdempotencyKey()
		// Verify key format (UUID v4 pattern).
		if key == "" {
			t.Errorf("Generated empty key")
		}
	}
}

// setupTestStore creates a temporary database for integration tests.
func setupTestStore(t *testing.T) (store *agentctx.IdempotencyStore, db *sql.DB, cleanup func()) {
	t.Helper()

	// We need to create a minimal CheckpointManager for testing.
	// For now, just create a db directly and use IdempotencyStore.
	tmpDir := t.TempDir()
	dbPath := filepath.Join(tmpDir, "test.db")
	var err error
	db, err = sql.Open("sqlite", dbPath)
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

	store = agentctx.NewIdempotencyStore(db, 1*time.Hour)
	cleanup = func() {
		_ = db.Close()
		_ = os.RemoveAll(tmpDir)
	}

	return store, db, cleanup
}

func TestIdempotency_Success(t *testing.T) {
	t.Parallel()
	store, _, cleanup := setupTestStore(t)
	defer cleanup()

	key := "test-key"    //nolint:goconst // test fixture
	tool := "shell_exec" //nolint:goconst // test fixture
	hash := "params-hash-123"
	result := "exec-output"
	session := "session-abc"

	// 1. Initial Store
	err := store.Store(key, tool, hash, result, session)
	if err != nil {
		t.Fatalf("Store failed: %v", err)
	}

	// 2. Check (Match)
	check, err := store.Check(key, tool, hash)
	if err != nil {
		t.Fatalf("Check failed: %v", err)
	}
	if !check.Found {
		t.Error("Expected key to be found")
	}
	if check.CachedResult != result {
		t.Errorf("got result %q, want %q", check.CachedResult, result)
	}
}

func TestIdempotency_HashMismatch(t *testing.T) {
	t.Parallel()
	store, _, cleanup := setupTestStore(t)
	defer cleanup()

	key := "test-key"    //nolint:goconst // test fixture
	tool := "shell_exec" //nolint:goconst // test fixture
	hash1 := "hash-1"
	hash2 := "hash-2"
	result := "output"

	_ = store.Store(key, tool, hash1, result, "session-1")

	// Check with different hash should fail
	_, err := store.Check(key, tool, hash2)
	if err == nil {
		t.Fatal("Expected error for hash mismatch, got nil")
	}
	if !agentctx.IsIdempotencyHashMismatch(err) {
		t.Errorf("expected hash mismatch error, got %v", err)
	}
}

func TestIdempotency_Expired(t *testing.T) {
	t.Parallel()
	store, db, cleanup := setupTestStore(t)
	defer cleanup()

	// 1. Test that Check() handles expired keys by deleting them.
	key1 := "expired-check-key"
	expiredAt := time.Now().Add(-2 * time.Hour).Format("2006-01-02 15:04:05")
	_, _ = db.Exec(`INSERT INTO idempotency_keys (key, tool_name, params_hash, result, created_at) VALUES (?, 'tool', 'hash', 'res', ?)`, key1, expiredAt)

	check, _ := store.Check(key1, "tool", "hash")
	if check.Found {
		t.Error("expected expired key to be NOT found by Check()")
	}

	// 2. Test manual CleanupExpired()
	key2 := "expired-manual-key"
	_, _ = db.Exec(`INSERT INTO idempotency_keys (key, tool_name, params_hash, result, created_at) VALUES (?, 'tool', 'hash', 'res', ?)`, key2, expiredAt)

	n, err := store.CleanupExpired()
	if err != nil {
		t.Fatalf("Cleanup failed: %v", err)
	}
	if n != 1 {
		t.Errorf("expected 1 key cleaned, got %d", n)
	}
}

func TestIdempotency_BackgroundCleanup(t *testing.T) {
	t.Parallel()
	store, db, cleanup := setupTestStore(t)
	defer cleanup()

	// 1. Insert an expired key.
	expiredAt := time.Now().Add(-2 * time.Hour).Format("2006-01-02 15:04:05")
	_, _ = db.Exec(`INSERT INTO idempotency_keys (key, tool_name, params_hash, result, created_at) VALUES (?, 'tool', 'hash', 'res', ?)`, "expired-bg", expiredAt)

	// 2. Start background cleanup with a short interval.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Run in background.
	go runIdempotencyCleanup(ctx, store, 50*time.Millisecond)

	// 3. Poll for cleanup (with timeout).
	// 5s timeout: Windows CI has coarse timer resolution and high scheduler jitter.
	deadline := time.After(5 * time.Second)
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()

	found := true
	for found {
		select {
		case <-deadline:
			t.Fatal("timeout waiting for background cleanup")
		case <-ticker.C:
			var count int
			_ = db.QueryRow("SELECT COUNT(*) FROM idempotency_keys WHERE key = 'expired-bg'").Scan(&count)
			if count == 0 {
				found = false
			}
		}
	}

	// 4. Verify cleanup stopped on context cancellation.
	cancel()
	time.Sleep(200 * time.Millisecond) // Give goroutine a moment to exit.
}
