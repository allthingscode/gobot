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

	return db, nil
}

// initSchema creates the threads and checkpoints tables if they do not exist.
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

	return nil
}
