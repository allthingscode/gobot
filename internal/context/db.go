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

// vacuumFreelistThreshold is the number of free pages above which reclaimIfBloated
// runs a one-time VACUUM. At SQLite's 4 KB default page size this is ~1 MB of
// reclaimable space - enough to ignore normal churn but catch the large backlog a
// pre-C-335 database accumulated before checkpoint retention was bounded.
const vacuumFreelistThreshold = 256

// reclaimIfBloated runs a single VACUUM when the freelist has grown past
// vacuumFreelistThreshold pages. Checkpoint pruning (C-335) returns superseded
// rows' pages to the freelist; in WAL mode SQLite reuses those pages for later
// inserts, so steady-state size plateaus without a VACUUM. The one-time VACUUM
// only reclaims the historical bloat an existing database carried in before the
// prune took effect. It must run on a freshly opened handle with no concurrent
// writers (VACUUM cannot run inside a transaction).
func reclaimIfBloated(db *sql.DB) error {
	var freelist int
	if err := db.QueryRowContext(stdctx.Background(), "PRAGMA freelist_count").Scan(&freelist); err != nil {
		return fmt.Errorf("reclaimIfBloated: read freelist_count: %w", err)
	}
	if freelist <= vacuumFreelistThreshold {
		return nil
	}
	if _, err := db.ExecContext(stdctx.Background(), "VACUUM"); err != nil {
		return fmt.Errorf("reclaimIfBloated: vacuum: %w", err)
	}
	return nil
}

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
func addChecksumColumnIfMissing(db sqlExecQuerier) error {
	rows, err := db.QueryContext(stdctx.Background(), "PRAGMA table_info(checkpoints)")
	if err != nil {
		return fmt.Errorf("query checkpoints table info: %w", err)
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
			return fmt.Errorf("scan table info: %w", err)
		}
		if name == "checksum" {
			return nil
		}
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("iterate table info rows: %w", err)
	}

	_, err = db.ExecContext(stdctx.Background(), "ALTER TABLE checkpoints ADD COLUMN checksum TEXT")
	if err != nil {
		return fmt.Errorf("alter checkpoints table: %w", err)
	}
	return nil
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
			return false, fmt.Errorf("scan threads table info: %w", err)
		}
		if name == colName {
			return true, nil
		}
	}
	if err := rows.Err(); err != nil {
		return false, fmt.Errorf("iterate threads table info rows: %w", err)
	}
	return false, nil
}

func hasColumn(db sqlExecQuerier, colName string) (bool, error) {
	rows, err := db.QueryContext(stdctx.Background(), "PRAGMA table_info(threads)")
	if err != nil {
		return false, fmt.Errorf("query threads table info: %w", err)
	}
	defer func() { _ = rows.Close() }()
	return checkColumnExists(rows, colName)
}

func addTokenColumnsIfMissing(db sqlExecQuerier) error {
	hasTokens, err := hasColumn(db, "estimated_tokens")
	if err != nil {
		return fmt.Errorf("check estimated_tokens: %w", err)
	}
	if !hasTokens {
		if _, err := db.ExecContext(stdctx.Background(), "ALTER TABLE threads ADD COLUMN estimated_tokens INTEGER DEFAULT 0"); err != nil {
			return fmt.Errorf("addTokenColumnsIfMissing: estimated_tokens: %w", err)
		}
	}
	hasCompactedAt, err := hasColumn(db, "last_compacted_at")
	if err != nil {
		return fmt.Errorf("check last_compacted_at: %w", err)
	}
	if !hasCompactedAt {
		if _, err := db.ExecContext(stdctx.Background(), "ALTER TABLE threads ADD COLUMN last_compacted_at DATETIME"); err != nil {
			return fmt.Errorf("addTokenColumnsIfMissing: last_compacted_at: %w", err)
		}
	}
	return nil
}

// sqlExecQuerier is satisfied by both *sql.DB and *sql.Tx, so schema helpers can
// run either directly or inside a migration transaction.
type sqlExecQuerier interface {
	ExecContext(ctx stdctx.Context, query string, args ...any) (sql.Result, error)
	QueryContext(ctx stdctx.Context, query string, args ...any) (*sql.Rows, error)
}

// migration is a single, versioned schema change. Migrations are applied in
// ascending version order, each inside its own transaction.
type migration struct {
	version int
	name    string
	apply   func(q sqlExecQuerier) error
}

// schemaMigrations returns the ordered schema history. To add a schema change,
// append a new entry with the next version number and an apply func - do NOT
// edit an existing migration or stitch a bespoke ALTER into initSchema.
func schemaMigrations() []migration {
	return []migration{
		{
			version: 1,
			name:    "baseline schema",
			apply: func(q sqlExecQuerier) error {
				if err := createBaseTables(q); err != nil {
					return fmt.Errorf("create base tables: %w", err)
				}
				if err := createIndices(q); err != nil {
					return fmt.Errorf("create indices: %w", err)
				}
				if err := createIdempotencyTable(q); err != nil {
					return fmt.Errorf("create idempotency table: %w", err)
				}
				if err := addChecksumColumnIfMissing(q); err != nil {
					return fmt.Errorf("add checksum column: %w", err)
				}
				if err := addTokenColumnsIfMissing(q); err != nil {
					return fmt.Errorf("add token columns: %w", err)
				}
				if err := createHITLApprovalsTable(q); err != nil {
					return err
				}
				return nil
			},
		},
	}
}

// initSchema brings the database up to the latest schema version. It is
// idempotent and safe to call repeatedly on both fresh and existing databases.
func initSchema(db *sql.DB) error {
	if err := runMigrations(db, schemaMigrations()); err != nil {
		return fmt.Errorf("initSchema: %w", err)
	}
	return nil
}

// runMigrations applies every migration whose version exceeds the database's
// current PRAGMA user_version, in ascending order, stamping the new version
// after each. An up-to-date database executes no migration statements.
func runMigrations(db *sql.DB, migs []migration) error {
	var current int
	if err := db.QueryRowContext(stdctx.Background(), "PRAGMA user_version").Scan(&current); err != nil {
		return fmt.Errorf("read user_version: %w", err)
	}
	for _, m := range migs {
		if m.version <= current {
			continue
		}
		if err := applyMigration(db, m); err != nil {
			return fmt.Errorf("migration %d (%s): %w", m.version, m.name, err)
		}
	}
	return nil
}

// applyMigration runs one migration inside a transaction and stamps user_version
// on success. Any failure rolls back the whole migration so the database is
// never left half-migrated.
func applyMigration(db *sql.DB, m migration) error {
	tx, err := db.BeginTx(stdctx.Background(), nil)
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
	}
	if err := m.apply(tx); err != nil {
		_ = tx.Rollback()
		return err
	}
	// PRAGMA user_version does not accept a bound parameter; the value is a
	// hardcoded int from the migrations list, never user input.
	//nolint:gosec // version is a trusted constant, not user-controlled
	if _, err := tx.ExecContext(stdctx.Background(), fmt.Sprintf("PRAGMA user_version = %d", m.version)); err != nil {
		_ = tx.Rollback()
		return fmt.Errorf("stamp user_version: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit: %w", err)
	}
	return nil
}

// createHITLApprovalsTable creates the hitl_approvals table if it does not exist.
func createHITLApprovalsTable(q sqlExecQuerier) error {
	_, err := q.ExecContext(stdctx.Background(), `
		CREATE TABLE IF NOT EXISTS hitl_approvals (
			request_id   TEXT PRIMARY KEY,
			session_key  TEXT NOT NULL,
			tool_name    TEXT NOT NULL,
			args         JSON NOT NULL,
			status       TEXT NOT NULL, -- 'pending', 'approved', 'rejected'
			created_at   DATETIME DEFAULT CURRENT_TIMESTAMP,
			decided_at   DATETIME
		)
	`)
	if err != nil {
		return fmt.Errorf("create hitl_approvals: %w", err)
	}
	return nil
}

func createBaseTables(db sqlExecQuerier) error {
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
	return nil
}

func createIndices(db sqlExecQuerier) error {
	_, err := db.ExecContext(stdctx.Background(), `
		CREATE INDEX IF NOT EXISTS idx_checkpoints_thread_iteration 
		ON checkpoints(thread_id, iteration DESC)
	`)
	if err != nil {
		return fmt.Errorf("initSchema: create idx_checkpoints_thread_iteration: %w", err)
	}
	return nil
}

func createIdempotencyTable(db sqlExecQuerier) error {
	_, err := db.ExecContext(stdctx.Background(), `
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
