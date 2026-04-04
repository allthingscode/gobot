package context

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"

	_ "modernc.org/sqlite" // register "sqlite" driver
)

const dbFileName = "checkpoints.db"

// openDB opens (or creates) the SQLite database at
// {storageRoot}/workspace/checkpoints.db with WAL mode enabled.
// The caller is responsible for closing the returned *sql.DB.
func openDB(storageRoot string) (*sql.DB, error) {
	dir := filepath.Join(storageRoot, "workspace")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("openDB: create workspace dir: %w", err)
	}

	dbPath := filepath.Join(dir, dbFileName)
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return nil, fmt.Errorf("openDB: open %s: %w", dbPath, err)
	}

	if _, err := db.Exec("PRAGMA journal_mode=WAL"); err != nil {
		db.Close()
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
	rows, err := db.Query("PRAGMA table_info(checkpoints)")
	if err != nil {
		return err
	}
	defer rows.Close()

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

	_, err = db.Exec("ALTER TABLE checkpoints ADD COLUMN checksum TEXT")
	return err
}

// initSchema creates the threads, checkpoints, and idempotency_keys tables if they do not exist.
func initSchema(db *sql.DB) error {
	_, err := db.Exec(`
		CREATE TABLE IF NOT EXISTS threads (
			thread_id  TEXT PRIMARY KEY,
			status     TEXT    DEFAULT 'active',
			model      TEXT,
			metadata   JSON,
			updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
		)
	`)
	if err != nil {
		return fmt.Errorf("initSchema: create threads: %w", err)
	}

	_, err = db.Exec(`
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

	if err := addChecksumColumnIfMissing(db); err != nil {
		return fmt.Errorf("initSchema: add checksum column: %w", err)
	}

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
		return fmt.Errorf("initSchema: create idempotency_keys: %w", err)
	}

	_, err = db.Exec(`
		CREATE INDEX IF NOT EXISTS idx_idempotency_session
		ON idempotency_keys(session_key)
	`)
	if err != nil {
		return fmt.Errorf("initSchema: create idx_idempotency_session: %w", err)
	}

	_, err = db.Exec(`
		CREATE INDEX IF NOT EXISTS idx_idempotency_created
		ON idempotency_keys(created_at)
	`)
	if err != nil {
		return fmt.Errorf("initSchema: create idx_idempotency_created: %w", err)
	}

	return nil
}
