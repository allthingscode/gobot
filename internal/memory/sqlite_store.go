package memory

import (
	"database/sql"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite" // register "sqlite" driver
)

const memoryDBFileName = "memory.db"

// MemoryStore is a SQLite FTS5-backed long-term memory index.
// It indexes agent responses by session key and supports full-text search.
type MemoryStore struct {
	db *sql.DB
}

// NewMemoryStore opens (or creates) the memory database at
// {storageRoot}/workspace/memory.db with WAL mode enabled.
// The caller is responsible for calling Close when done.
func NewMemoryStore(storageRoot string) (*MemoryStore, error) {
	dir := filepath.Join(storageRoot, "workspace")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("memory: mkdir: %w", err)
	}

	dbPath := filepath.Join(dir, memoryDBFileName)
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return nil, fmt.Errorf("memory: open db: %w", err)
	}

	if _, err := db.Exec("PRAGMA journal_mode=WAL"); err != nil {
		db.Close()
		return nil, fmt.Errorf("memory: WAL mode: %w", err)
	}
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)

	if err := initMemorySchema(db); err != nil {
		db.Close()
		return nil, fmt.Errorf("memory: schema: %w", err)
	}
	return &MemoryStore{db: db}, nil
}

func initMemorySchema(db *sql.DB) error {
	_, err := db.Exec(`
		CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
			session_key UNINDEXED,
			content,
			timestamp   UNINDEXED
		)
	`)
	if err != nil {
		return fmt.Errorf("initMemorySchema: create memory_fts: %w", err)
	}
	return nil
}

// Index adds content to the memory index under sessionKey.
// Empty or whitespace-only content is silently ignored.
func (m *MemoryStore) Index(sessionKey, content string) error {
	if strings.TrimSpace(content) == "" {
		return nil
	}
	ts := time.Now().UTC().Format(time.RFC3339)
	_, err := m.db.Exec(
		`INSERT INTO memory_fts(session_key, content, timestamp) VALUES (?, ?, ?)`,
		sessionKey, content, ts,
	)
	if err != nil {
		return fmt.Errorf("memory: index: %w", err)
	}
	return nil
}

// Search performs a full-text search and returns up to limit results as
// []map[string]any with "session_key", "content", and "timestamp" keys.
// Compatible with FilterRAGResults and FormatRAGBlock.
//
// Returns nil (not an error) when the query is empty, no results match,
// or FTS5 rejects the query syntax.
func (m *MemoryStore) Search(query string, limit int) ([]map[string]any, error) {
	safe := sanitizeFTSQuery(query)
	if safe == "" || limit <= 0 {
		return nil, nil
	}
	rows, err := m.db.Query(
		`SELECT session_key, content, timestamp
		 FROM memory_fts
		 WHERE memory_fts MATCH ?
		 ORDER BY rank
		 LIMIT ?`,
		safe, limit,
	)
	if err != nil {
		// FTS5 returns an error on bad query syntax — treat as empty result set.
		slog.Debug("memory: search query rejected (returning empty)", "err", err)
		return nil, nil
	}
	defer rows.Close()

	var results []map[string]any
	for rows.Next() {
		var sessionKey, content, timestamp string
		if err := rows.Scan(&sessionKey, &content, &timestamp); err != nil {
			continue
		}
		results = append(results, map[string]any{
			"session_key": sessionKey,
			"content":     content,
			"timestamp":   timestamp,
		})
	}
	if err := rows.Err(); err != nil {
		return results, fmt.Errorf("memory: search scan: %w", err)
	}
	return results, nil
}

// Rebuild walks sessionDir and re-indexes every .md file it finds.
// Each file is indexed under a session key derived from the filename (no extension).
// Does not clear existing entries — existing duplicates may accumulate; run a
// fresh database if a clean rebuild is required.
//
// Returns the count of files successfully indexed.
func (m *MemoryStore) Rebuild(sessionDir string) (int, error) {
	count := 0
	err := filepath.WalkDir(sessionDir, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil || d.IsDir() || !strings.HasSuffix(path, ".md") {
			return walkErr
		}
		data, err := os.ReadFile(path)
		if err != nil {
			slog.Warn("memory rebuild: skipping unreadable file", "path", path, "err", err)
			return nil
		}
		sessionKey := strings.TrimSuffix(filepath.Base(path), ".md")
		if err := m.Index(sessionKey, string(data)); err != nil {
			slog.Warn("memory rebuild: index failed", "path", path, "err", err)
			return nil
		}
		count++
		return nil
	})
	return count, err
}

// CleanupExpired removes entries older than the specified duration.
// ttl should be a duration string like "2160h" (90 days) or "720h" (30 days).
// If ttl is empty or invalid, this is a no-op (returns nil).
// Returns the number of rows deleted.
func (m *MemoryStore) CleanupExpired(ttl string) (int64, error) {
	if ttl == "" {
		return 0, nil
	}
	duration, err := time.ParseDuration(ttl)
	if err != nil {
		slog.Warn("memory: invalid TTL duration", "ttl", ttl, "err", err)
		return 0, nil
	}
	if duration <= 0 {
		return 0, nil
	}
	cutoff := time.Now().UTC().Add(-duration)
	result, err := m.db.Exec(
		`DELETE FROM memory_fts WHERE timestamp < ?`,
		cutoff.Format(time.RFC3339),
	)
	if err != nil {
		return 0, fmt.Errorf("memory: cleanup: %w", err)
	}
	deleted, err := result.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("memory: rows affected: %w", err)
	}
	if deleted > 0 {
		slog.Info("memory: cleanup removed expired entries", "count", deleted, "ttl", ttl)
	}
	return deleted, nil
}

// Close releases the database connection.
func (m *MemoryStore) Close() error {
	return m.db.Close()
}

// sanitizeFTSQuery removes FTS5 operator characters that could cause parse
// errors when a raw user message is passed as a search query.
func sanitizeFTSQuery(q string) string {
	r := strings.NewReplacer(
		`"`, ` `, `(`, ` `, `)`, ` `, `*`, ` `,
		`^`, ` `, `-`, ` `, `+`, ` `, `{`, ` `, `}`, ` `,
		`:`, ` `, `[`, ` `, `]`, ` `, `,`, ` `,
	)
	cleaned := strings.Join(strings.Fields(r.Replace(q)), " ")
	return cleaned
}
