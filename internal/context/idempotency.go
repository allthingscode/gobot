package context

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

// IdempotencyStore manages idempotency keys for side-effecting tool calls.
// It prevents duplicate execution when the agent loop retries tool calls
// after timeouts or transient failures.
type IdempotencyStore struct {
	db  *sql.DB
	ttl time.Duration
}

// IdempotencyRecord represents a single idempotency key entry.
type IdempotencyRecord struct {
	Key        string
	ToolName   string
	ParamsHash string
	Result     string
	SessionKey string
	CreatedAt  time.Time
}

// NewIdempotencyStore creates a new IdempotencyStore backed by the given SQLite database.
// The ttl parameter controls how long idempotency keys are retained (default 24h).
func NewIdempotencyStore(db *sql.DB, ttl time.Duration) *IdempotencyStore {
	return &IdempotencyStore{
		db:  db,
		ttl: ttl,
	}
}

// HashParams computes a SHA-256 hash of the tool parameters map.
// This is used to detect when the same idempotency key is used with
// different parameters (which should be rejected).
func HashParams(params map[string]any) (string, error) {
	data, err := json.Marshal(params)
	if err != nil {
		return "", fmt.Errorf("hash params: marshal JSON: %w", err)
	}
	hash := sha256.Sum256(data)
	return hex.EncodeToString(hash[:]), nil
}

// CheckResult is returned by Check() with information about an idempotency key.
type CheckResult struct {
	// Found indicates the key exists in the store.
	Found bool
	// CachedResult is the previously computed result (only valid if Found=true).
	CachedResult string
	// HashMismatch indicates the key exists but with different params_hash
	// (this is an error condition — same key, different params).
	HashMismatch bool
}

// Check looks up an idempotency key and verifies the params hash matches.
// Returns CheckResult with Found=true if the key exists and params match,
// allowing the caller to return the cached result.
// Returns CheckResult with HashMismatch=true if the key exists but params don't match
// (caller should return an error).
func (s *IdempotencyStore) Check(key, _, paramsHash string) (CheckResult, error) {
	var storedHash, storedResult string
	var createdAt string

	err := s.db.QueryRow(`
		SELECT params_hash, result, created_at
		FROM idempotency_keys
		WHERE key = ?
	`, key).Scan(&storedHash, &storedResult, &createdAt)

	if errors.Is(err, sql.ErrNoRows) {
		// Key not found — caller should execute the tool.
		return CheckResult{Found: false}, nil
	}
	if err != nil {
		return CheckResult{}, fmt.Errorf("check idempotency key: %w", err)
	}

	// Key found — check if params match.
	if storedHash != paramsHash {
		return CheckResult{
			Found:        true,
			HashMismatch: true,
		}, fmt.Errorf("idempotency key %s reused with different parameters", key)
	}

	// Parse created_at to check TTL.
	createdTime, err := time.Parse(time.RFC3339, createdAt)
	if err != nil {
		// Fallback: try common SQLite datetime format.
		createdTime, err = time.Parse("2006-01-02 15:04:05", createdAt)
		if err != nil {
			return CheckResult{}, fmt.Errorf("parse created_at: %w", err)
		}
	}

	// Check if record has expired.
	if time.Since(createdTime) > s.ttl {
		// Expired — delete it and treat as not found.
		_, _ = s.db.Exec("DELETE FROM idempotency_keys WHERE key = ?", key)
		return CheckResult{Found: false}, nil
	}

	// Cache hit — return cached result.
	return CheckResult{
		Found:        true,
		CachedResult: storedResult,
	}, nil
}

// Store saves an idempotency key with the associated tool name, params hash, and result.
// Future calls to Check() with the same key will return this cached result
// (as long as the params hash matches and TTL hasn't expired).
func (s *IdempotencyStore) Store(key, toolName, paramsHash, result, sessionKey string) error {
	_, err := s.db.Exec(`
		INSERT INTO idempotency_keys (key, tool_name, params_hash, result, session_key, created_at)
		VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
	`, key, toolName, paramsHash, result, sessionKey)
	if err != nil {
		return fmt.Errorf("store idempotency key: %w", err)
	}
	return nil
}

// CleanupExpired deletes all idempotency records older than the TTL.
// This should be called periodically (e.g., on startup or via a background goroutine)
// to prevent the table from growing unbounded.
func (s *IdempotencyStore) CleanupExpired() (int64, error) {
	cutoff := time.Now().Add(-s.ttl)
	cutoffStr := cutoff.Format("2006-01-02 15:04:05")

	res, err := s.db.Exec(`
		DELETE FROM idempotency_keys
		WHERE created_at < ?
	`, cutoffStr)
	if err != nil {
		return 0, fmt.Errorf("cleanup expired idempotency keys: %w", err)
	}

	rowsAffected, err := res.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("get rows affected: %w", err)
	}

	return rowsAffected, nil
}

// IsIdempotencyHashMismatch returns true if the error indicates an idempotency key
// was reused with different parameters.
func IsIdempotencyHashMismatch(err error) bool {
	if err == nil {
		return false
	}
	return strings.Contains(err.Error(), "reused with different parameters")
}
