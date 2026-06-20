//nolint:testpackage // exercises unexported migration runner internals
package context

import (
	stdctx "context"
	"database/sql"
	"testing"
)

func readUserVersion(t *testing.T, db *sql.DB) int {
	t.Helper()
	var v int
	if err := db.QueryRowContext(stdctx.Background(), "PRAGMA user_version").Scan(&v); err != nil {
		t.Fatalf("read user_version: %v", err)
	}
	return v
}

func tableExists(t *testing.T, db *sql.DB, name string) bool {
	t.Helper()
	var n int
	err := db.QueryRowContext(stdctx.Background(),
		"SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?", name).Scan(&n)
	if err != nil {
		t.Fatalf("table exists query: %v", err)
	}
	return n > 0
}

func latestVersion() int {
	v := 0
	for _, m := range schemaMigrations() {
		if m.version > v {
			v = m.version
		}
	}
	return v
}

// AC1/AC8: a fresh DB migrates to the latest version with the full schema.
func TestRunMigrations_FreshDB(t *testing.T) {
	t.Parallel()
	db, err := openDB(t.TempDir())
	if err != nil {
		t.Fatalf("openDB: %v", err)
	}
	defer func() { _ = db.Close() }()

	if err := initSchema(db); err != nil {
		t.Fatalf("initSchema: %v", err)
	}
	if got := readUserVersion(t, db); got != latestVersion() {
		t.Errorf("user_version = %d, want %d", got, latestVersion())
	}
	for _, table := range []string{"threads", "checkpoints", "idempotency_keys", "hitl_approvals"} {
		if !tableExists(t, db, table) {
			t.Errorf("expected table %q to exist after migration", table)
		}
	}
	// The migrated columns must be usable.
	if _, err := db.ExecContext(stdctx.Background(),
		"INSERT INTO threads(thread_id, estimated_tokens, last_compacted_at) VALUES('t1', 5, NULL)"); err != nil {
		t.Errorf("insert using migrated threads columns: %v", err)
	}
	if _, err := db.ExecContext(stdctx.Background(),
		"INSERT INTO checkpoints(thread_id, checksum) VALUES('t1', 'abc')"); err != nil {
		t.Errorf("insert using migrated checkpoints.checksum column: %v", err)
	}
}

// AC4: initSchema is idempotent - a second call is a no-op and user_version is stable.
func TestInitSchema_Idempotent(t *testing.T) {
	t.Parallel()
	db, err := openDB(t.TempDir())
	if err != nil {
		t.Fatalf("openDB: %v", err)
	}
	defer func() { _ = db.Close() }()

	if err := initSchema(db); err != nil {
		t.Fatalf("first initSchema: %v", err)
	}
	v1 := readUserVersion(t, db)
	if err := initSchema(db); err != nil {
		t.Fatalf("second initSchema: %v", err)
	}
	if v2 := readUserVersion(t, db); v2 != v1 {
		t.Errorf("user_version changed on idempotent re-run: %d -> %d", v1, v2)
	}
}

// AC3/AC5: a pre-versioning DB (schema already built by the old ad-hoc path,
// user_version still 0, with real data) migrates cleanly with no duplicate-column
// error and preserves existing rows.
func TestRunMigrations_PreVersioningDB(t *testing.T) {
	t.Parallel()
	db, err := openDB(t.TempDir())
	if err != nil {
		t.Fatalf("openDB: %v", err)
	}
	defer func() { _ = db.Close() }()

	// Simulate the old ad-hoc path: build the v1 schema directly against the DB
	// WITHOUT stamping user_version (it stays 0), then seed a row.
	if err := schemaMigrations()[0].apply(db); err != nil {
		t.Fatalf("seed pre-versioning schema: %v", err)
	}
	if got := readUserVersion(t, db); got != 0 {
		t.Fatalf("precondition: expected user_version 0, got %d", got)
	}
	if _, err := db.ExecContext(stdctx.Background(),
		"INSERT INTO threads(thread_id, status, estimated_tokens) VALUES('keep-me', 'active', 42)"); err != nil {
		t.Fatalf("seed row: %v", err)
	}

	if err := initSchema(db); err != nil {
		t.Fatalf("migrate pre-versioning DB: %v", err)
	}
	if got := readUserVersion(t, db); got != latestVersion() {
		t.Errorf("user_version = %d, want %d", got, latestVersion())
	}

	var status string
	var tokens int
	if err := db.QueryRowContext(stdctx.Background(),
		"SELECT status, estimated_tokens FROM threads WHERE thread_id='keep-me'").Scan(&status, &tokens); err != nil {
		t.Fatalf("read preserved row: %v", err)
	}
	if status != "active" || tokens != 42 {
		t.Errorf("data not preserved: status=%q tokens=%d", status, tokens)
	}
}

// AC2: a failing migration is rolled back in full - user_version is unchanged and
// none of the migration's partial DDL persists.
func TestRunMigrations_RollbackOnFailure(t *testing.T) {
	t.Parallel()
	db, err := openDB(t.TempDir())
	if err != nil {
		t.Fatalf("openDB: %v", err)
	}
	defer func() { _ = db.Close() }()

	baseline := schemaMigrations()[0]
	if err := runMigrations(db, []migration{baseline}); err != nil {
		t.Fatalf("baseline migrate: %v", err)
	}
	before := readUserVersion(t, db)

	failing := migration{
		version: baseline.version + 1,
		name:    "intentionally failing",
		apply: func(q sqlExecQuerier) error {
			if _, err := q.ExecContext(stdctx.Background(), "CREATE TABLE rollback_canary (x INTEGER)"); err != nil {
				return err
			}
			// Invalid SQL forces the transaction to roll back.
			_, err := q.ExecContext(stdctx.Background(), "THIS IS NOT VALID SQL")
			return err
		},
	}

	err = runMigrations(db, []migration{baseline, failing})
	if err == nil {
		t.Fatal("expected runMigrations to return an error for the failing migration")
	}
	if after := readUserVersion(t, db); after != before {
		t.Errorf("user_version changed despite rollback: %d -> %d", before, after)
	}
	if tableExists(t, db, "rollback_canary") {
		t.Error("rollback_canary table persisted; failing migration was not rolled back")
	}
}
