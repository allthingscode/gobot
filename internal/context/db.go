package context

import (
	stdctx "context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"

	_ "modernc.org/sqlite" // register "sqlite" driver
)

const dbFileName = "checkpoints.db"

// openDB opens (or creates) the SQLite database at dbDir/workspace/checkpoints.db
// with WAL mode enabled. The caller is responsible for closing the returned *sql.DB.
func openDB(dbDir string) (*sql.DB, error) {
	workspaceDir := filepath.Join(dbDir, "workspace")
	if err := os.MkdirAll(workspaceDir, 0o755); err != nil {
		return nil, fmt.Errorf("openDB: create workspace dir: %w", err)
	}

	dbPath := filepath.Join(workspaceDir, dbFileName)
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return nil, fmt.Errorf("openDB: open %s: %w", dbPath, err)
	}

	if _, err := db.ExecContext(stdctx.Background(), "PRAGMA journal_mode=WAL"); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("openDB: set WAL mode: %w", err)
	}

	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)

	return db, nil
}

// addChecksumColumnIfMissing adds a checksum TEXT column to the checkpoints
// table if it does not already exist. It is idempotent and safe to call on
// both fresh and existing databases.
func addChecksumColumnIfMissing(db *sql.DB) error {
	rows, err := db.QueryContext(stdctx.Background(), "PRAGMA table_info(checkpoints)")
	if err != nil {
		return err
	}
	defer func() { _ = rows.Close() }()

	for rows.Next() {
		var cid int
		var name string
		var typeStr string
		var notNull int
		var dfltValue sql.NullString
		var pk int
		if err := rows.Scan(&cid, &name, &typeStr, &notNull, &dfltValue, &pk); err != nil {
			return err
		}
		if name == "checksum" {
			return nil
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}

	_, err = db.ExecContext(stdctx.Background(), "ALTER TABLE checkpoints ADD COLUMN checksum TEXT")
	return err
}

// addTokenColumnsIfMissing adds estimated_tokens and last_compacted_at columns
// to the threads table if they do not already exist. Idempotent and safe for
// existing databases.
func checkColumnExists(rows *sql.Rows, colName string) (exists bool, err error) {
	for rows.Next() {
		var cid int
		var name string
		var typeStr string
		var notNull int
		var dfltValue sql.NullString
		var pk int
		if err := rows.Scan(&cid, &name, &typeStr, &notNull, &dfltValue, &pk); err != nil {
			return false, err
		}
		if name == colName {
			return true, nil
		}
	}
	return false, rows.Err()
}

func hasColumn(db *sql.DB, colName string) (bool, error) {
	rows, err := db.QueryContext(stdctx.Background(), "PRAGMA table_info(threads)")
	if err != nil {
		return false, err
	}
	defer func() { _ = rows.Close() }()
	return checkColumnExists(rows, colName)
}

func addTokenColumnsIfMissing(db *sql.DB) error {
	hasTokens, err := hasColumn(db, "estimated_tokens")
	if err != nil {
		return err
	}
	if !hasTokens {
		if _, err := db.ExecContext(stdctx.Background(), "ALTER TABLE threads ADD COLUMN estimated_tokens INTEGER DEFAULT 0"); err != nil {
			return fmt.Errorf("addTokenColumnsIfMissing: estimated_tokens: %w", err)
		}
	}
	hasCompactedAt, err := hasColumn(db, "last_compacted_at")
	if err != nil {
		return err
	}
	if !hasCompactedAt {
		if _, err := db.ExecContext(stdctx.Background(), "ALTER TABLE threads ADD COLUMN last_compacted_at DATETIME"); err != nil {
			return fmt.Errorf("addTokenColumnsIfMissing: last_compacted_at: %w", err)
		}
	}
	return nil
}

// initSchema creates the threads, checkpoints, and idempotency_keys tables if they do not exist.
func initSchema(db *sql.DB) error {
	_, err := db.ExecContext(stdctx.Background(), `
		CREATE TABLE IF NOT EXISTS threads (
			thread_id         TEXT PRIMARY KEY,
			status            TEXT    DEFAULT 'active',
			model             TEXT,
			metadata          JSON,
			updated_at        DATETIME DEFAULT CURRENT_TIMESTAMP,
			estimated_tokens  INTEGER DEFAULT 0,
			last_compacted_at DATETIME
		)
	`)
	if err != nil {
		return fmt.Errorf("initSchema: create threads: %w", err)
	}

	_, err = db.ExecContext(stdctx.Background(), `
		CREATE TABLE IF NOT EXISTS checkpoints (
			checkpoint_id INTEGER PRIMARY KEY AUTOINCREMENT,
			thread_id     TEXT,
			iteration     INTEGER,
			state         JSON,
			created_at    DATETIME DEFAULT CURRENT_TIMESTAMP,
			FOREIGN KEY (thread_id) REFERENCES threads(thread_id)
		)
	`)
	if err != nil {
		return fmt.Errorf("initSchema: create checkpoints: %w", err)
	}

	_, err = db.ExecContext(stdctx.Background(), `
		CREATE INDEX IF NOT EXISTS idx_checkpoints_thread_iteration 
		ON checkpoints(thread_id, iteration DESC)
	`)
	if err != nil {
		return fmt.Errorf("initSchema: create idx_checkpoints_thread_iteration: %w", err)
	}

	if err := addChecksumColumnIfMissing(db); err != nil {
		return fmt.Errorf("initSchema: add checksum column: %w", err)
	}

	if err := addTokenColumnsIfMissing(db); err != nil {
		return fmt.Errorf("initSchema: add token columns: %w", err)
	}

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
		return fmt.Errorf("initSchema: create idempotency_keys: %w", err)
	}

	_, err = db.ExecContext(stdctx.Background(), `
		CREATE INDEX IF NOT EXISTS idx_idempotency_session
		ON idempotency_keys(session_key)
	`)
	if err != nil {
		return fmt.Errorf("initSchema: create idx_idempotency_session: %w", err)
	}

	_, err = db.ExecContext(stdctx.Background(), `
		CREATE INDEX IF NOT EXISTS idx_idempotency_created
		ON idempotency_keys(created_at)
	`)
	if err != nil {
		return fmt.Errorf("initSchema: create idx_idempotency_created: %w", err)
	}

	return nil
}
