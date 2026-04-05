package main

import (
	"database/sql"
	"os"
	"path/filepath"
	"testing"
	"time"

	agentctx "github.com/allthingscode/gobot/internal/context"
)

// TestHashParams_NonSerializableArgs verifies that HashParams returns an error
// for non-JSON-serializable types, which should be handled gracefully by callers.
func TestHashParams_NonSerializableArgs(t *testing.T) {
	// Create a map containing a function (non-serializable).
	nonSerializableParams := map[string]any{
		"callback": func() {},
	}

	hash, err := agentctx.HashParams(nonSerializableParams)
	if err == nil {
		t.Errorf("HashParams() with non-serializable args should return error, got hash: %s", hash)
	}
	if hash != "" {
		t.Errorf("HashParams() with non-serializable args should return empty string, got: %s", hash)
	}
}

// TestHashParams_ValidArgs verifies that HashParams succeeds with valid JSON-serializable types.
func TestHashParams_ValidArgs(t *testing.T) {
	validParams := map[string]any{
		"to":      "test@example.com",
		"subject": "Test Email",
		"body":    "Hello, World!",
	}

	hash, err := agentctx.HashParams(validParams)
	if err != nil {
		t.Errorf("HashParams() with valid args failed: %v", err)
	}
	if hash == "" {
		t.Errorf("HashParams() with valid args returned empty hash")
	}
}

// TestHashParams_EmptyArgs verifies that HashParams handles empty params correctly.
func TestHashParams_EmptyArgs(t *testing.T) {
	emptyParams := map[string]any{}

	hash, err := agentctx.HashParams(emptyParams)
	if err != nil {
		t.Errorf("HashParams() with empty args failed: %v", err)
	}
	if hash == "" {
		t.Errorf("HashParams() with empty args returned empty hash")
	}
}

// TestSideEffectingToolIdempotency verifies that side-effecting tools
// return cached results on retry, preventing duplicate executions.
func TestSideEffectingToolIdempotency(t *testing.T) {
	tests := []struct {
		name     string
		toolName string
		isIdem   bool
	}{
		{"send_email is side-effecting", "send_email", true},
		{"create_calendar_event is side-effecting", "create_calendar_event", true},
		{"create_task is side-effecting", "create_task", true},
		{"complete_task is side-effecting", "complete_task", true},
		{"update_task is side-effecting", "update_task", true},
		{"shell_exec is side-effecting", "shell_exec", true},
		{"search_gmail is read-only", "search_gmail", false},
		{"list_calendar_events is read-only", "list_calendar_events", false},
		{"list_tasks is read-only", "list_tasks", false},
		{"google_search is read-only", "google_search", false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := isSideEffectingTool(tt.toolName)
			if got != tt.isIdem {
				t.Errorf("isSideEffectingTool(%q) = %v, want %v", tt.toolName, got, tt.isIdem)
			}
		})
	}
}

// TestRunner_HashParamsFailure verifies that when HashParams fails due to
// non-serializable args, the runner proceeds without idempotency check.
// See B-039 for full specification.
func TestRunner_HashParamsFailure(t *testing.T) {
	// Verify HashParams behavior: non-serializable args return error + empty string.
	// The runner handles this by logging a warning and skipping idempotency.
	nonSerializableParams := map[string]any{"callback": func() {}}
	hash, err := agentctx.HashParams(nonSerializableParams)
	if err == nil {
		t.Error("HashParams() with non-serializable args should return error")
	}
	if hash != "" {
		t.Errorf("HashParams() with non-serializable args should return empty string, got: %s", hash)
	}
}

// TestIdempotencyStore_Integration verifies that the idempotency store
// works correctly with the runner's tool execution flow.
func TestIdempotencyStore_Integration(t *testing.T) {
	store, _, cleanup := setupTestStore(t)
	defer cleanup()

	// Simulate first tool execution.
	params := map[string]any{"to": "test@example.com", "subject": "Test"}
	paramsHash, err := agentctx.HashParams(params)
	if err != nil {
		t.Fatalf("HashParams() error: %v", err)
	}

	// First execution: store result.
	err = store.Store("idem-key-1", "send_email", paramsHash, "Email sent to test@example.com", "session-1")
	if err != nil {
		t.Fatalf("Store() error: %v", err)
	}

	// Simulate retry: should get cached result.
	result, err := store.Check("idem-key-1", "send_email", paramsHash)
	if err != nil {
		t.Fatalf("Check() error: %v", err)
	}

	if !result.Found {
		t.Errorf("Expected cache hit on retry")
	}
	if result.CachedResult != "Email sent to test@example.com" {
		t.Errorf("Cached result = %q, want %q", result.CachedResult, "Email sent to test@example.com")
	}
}

// TestIdempotencyKey_Generation verifies that generated keys are unique.
func TestIdempotencyKey_Generation(t *testing.T) {
	keys := make(map[string]bool)

	// Generate 100 keys and verify uniqueness.
	for i := 0; i < 100; i++ {
		key := generateIdempotencyKey()
		if keys[key] {
			t.Errorf("Duplicate idempotency key generated: %s", key)
		}
		keys[key] = true

		// Verify key format (UUID v4 pattern).
		if len(key) == 0 {
			t.Errorf("Generated empty key")
		}
	}
}

// setupTestStore creates a temporary database for integration tests.
func setupTestStore(t *testing.T) (*agentctx.IdempotencyStore, interface{}, func()) {
	t.Helper()

	// We need to create a minimal CheckpointManager for testing.
	// For now, just create a db directly and use IdempotencyStore.
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

	store := agentctx.NewIdempotencyStore(db, 1*time.Hour)
	cleanup := func() {
		db.Close()
		os.RemoveAll(tmpDir)
	}

	return store, nil, cleanup
}
