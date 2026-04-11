package memory

import (
	"database/sql"
	"errors"
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
const maxRebuildFiles = 10_000

// MemoryStore is a SQLite FTS5-backed long-term memory index.
// It indexes agent responses by session key and supports full-text search.
//
// revive:disable:exported
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
		_ = db.Close()
		return nil, fmt.Errorf("memory: WAL mode: %w", err)
	}
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)

	if err := initMemorySchema(db); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("memory: schema: %w", err)
	}
	return &MemoryStore{db: db}, nil
}

func initMemorySchema(db *sql.DB) error {
	var version int
	if err := db.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		return fmt.Errorf("initMemorySchema: get version: %w", err)
	}

	if version == 0 {
		// Check if table exists with old schema
		var name string
		err := db.QueryRow("SELECT name FROM sqlite_master WHERE type='table' AND name='memory_fts'").Scan(&name)
		if err == nil {
			// Migrate: rename old, create new, copy data, drop old
			migration := []string{
				`ALTER TABLE memory_fts RENAME TO memory_fts_old`,
				`CREATE VIRTUAL TABLE memory_fts USING fts5(
					namespace UNINDEXED,
					content,
					timestamp UNINDEXED
				)`,
				`INSERT INTO memory_fts(namespace, content, timestamp)
				 SELECT 'session:' || session_key, content, timestamp FROM memory_fts_old`,
				`DROP TABLE memory_fts_old`,
				`PRAGMA user_version = 1`,
			}
			for _, stmt := range migration {
				if _, err := db.Exec(stmt); err != nil {
					return fmt.Errorf("migration failed: %s: %w", stmt, err)
				}
			}
			slog.Info("memory: schema migrated to V1 (namespaces)")
		} else {
			// Fresh install
			_, err := db.Exec(`
				CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
					namespace UNINDEXED,
					content,
					timestamp UNINDEXED
				);
				PRAGMA user_version = 1;
			`)
			if err != nil {
				return fmt.Errorf("initMemorySchema: create V1: %w", err)
			}
		}
	}
	return nil
}

// Index adds content to the memory index under the specified namespace.
// Empty or whitespace-only content is silently ignored.
func (m *MemoryStore) Index(namespace, content string) error {
	if strings.TrimSpace(content) == "" {
		return nil
	}
	ts := time.Now().UTC().Format(time.RFC3339)
	_, err := m.db.Exec(
		`INSERT INTO memory_fts(namespace, content, timestamp) VALUES (?, ?, ?)`,
		namespace, content, ts,
	)
	if err != nil {
		return fmt.Errorf("memory: index: %w", err)
	}
	return nil
}

// Search performs a full-text search and returns up to limit results as
// []map[string]any with "namespace", "content", and "timestamp" keys.
// It searches both the provided session namespace and the "global" namespace.
// Compatible with FilterRAGResults and FormatRAGBlock.
//
// Returns nil (not an error) when the query is empty, no results match,
// or FTS5 rejects the query syntax.
func (m *MemoryStore) Search(query, sessionKey string, limit int) ([]map[string]any, error) {
	safe := sanitizeFTSQuery(query)
	if safe == "" || limit <= 0 {
		return nil, nil
	}

	sessionNamespace := "session:" + sessionKey
	rows, err := m.db.Query(
		`SELECT namespace, content, timestamp
		 FROM memory_fts
		 WHERE memory_fts MATCH ? AND namespace IN (?, 'global')
		 ORDER BY rank
		 LIMIT ?`,
		safe, sessionNamespace, limit,
	)
	if err != nil {
		// FTS5 returns an error on bad query syntax — treat as empty result set.
		slog.Debug("memory: search query rejected (returning empty)", "err", err)
		return nil, nil
	}
	defer func() { _ = rows.Close() }()

	var results []map[string]any
	seen := make(map[string]bool)
	for rows.Next() {
		var namespace, content, timestamp string
		if err := rows.Scan(&namespace, &content, &timestamp); err != nil {
			continue
		}
		// Basic deduplication by content
		if seen[content] {
			continue
		}
		seen[content] = true

		results = append(results, map[string]any{
			"namespace": namespace,
			"content":   content,
			"timestamp": timestamp,
		})
	}
	if err := rows.Err(); err != nil {
		return results, fmt.Errorf("memory: search scan: %w", err)
	}
	return results, nil
}

// Rebuild walks sessionDir and re-indexes every .md file it finds.
// Each file is indexed under a session namespace 'session:{filename}'.
// Does not clear existing entries — existing duplicates may accumulate; run a
// fresh database if a clean rebuild is required.
//
// Returns the count of files successfully indexed.
func (m *MemoryStore) Rebuild(sessionDir string) (int, error) {
	count := 0
	errLimit := fmt.Errorf("memory: Rebuild truncated at maxFiles limit")
	err := filepath.WalkDir(sessionDir, func(path string, d fs.DirEntry, walkErr error) error {
		if count >= maxRebuildFiles {
			slog.Warn("memory: Rebuild truncated at maxFiles limit", "limit", maxRebuildFiles)
			return errLimit
		}
		if walkErr != nil || d.IsDir() || !strings.HasSuffix(path, ".md") {
			return walkErr
		}
		data, err := os.ReadFile(path)
		if err != nil {
			slog.Warn("memory rebuild: skipping unreadable file", "path", path, "err", err)
			return nil
		}
		sessionKey := strings.TrimSuffix(filepath.Base(path), ".md")
		namespace := "session:" + sessionKey
		if err := m.Index(namespace, string(data)); err != nil {
			slog.Warn("memory rebuild: index failed", "path", path, "err", err)
			return nil
		}
		count++
		return nil
	})
	if errors.Is(err, errLimit) {
		err = nil
	}
	return count, err
}

// CleanupNamespace removes entries in the specified namespace older than the TTL.
// ttl should be a duration string like "2160h" (90 days).
// If namespace is empty, it cleans up ALL namespaces (legacy behavior).
// If ttl is empty or invalid, this is a no-op (returns nil).
// Returns the number of rows deleted.
func (m *MemoryStore) CleanupNamespace(namespace, ttl string) (int64, error) {
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

	var result sql.Result
	if namespace == "" {
		result, err = m.db.Exec(
			`DELETE FROM memory_fts WHERE timestamp < ?`,
			cutoff.Format(time.RFC3339),
		)
	} else {
		result, err = m.db.Exec(
			`DELETE FROM memory_fts WHERE namespace = ? AND timestamp < ?`,
			namespace, cutoff.Format(time.RFC3339),
		)
	}

	if err != nil {
		return 0, fmt.Errorf("memory: cleanup %s: %w", namespace, err)
	}
	deleted, err := result.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("memory: rows affected: %w", err)
	}
	if deleted > 0 {
		slog.Info("memory: cleanup removed expired entries", "namespace", namespace, "count", deleted, "ttl", ttl)
	}
	return deleted, nil
}

// CleanupExpired is a legacy wrapper for CleanupNamespace("") to maintain backward compatibility.
func (m *MemoryStore) CleanupExpired(ttl string) (int64, error) {
	return m.CleanupNamespace("", ttl)
}

// Close releases the database connection.
func (m *MemoryStore) Close() error {
	return m.db.Close()
}

// Stats returns the total count of memory entries.
func (m *MemoryStore) Stats() (int, error) {
	var count int
	err := m.db.QueryRow("SELECT count(*) FROM memory_fts").Scan(&count)
	return count, err
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
