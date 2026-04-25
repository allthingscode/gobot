//nolint:testpackage // requires unexported pairing internals for testing
package context

import (
	stdctx "context"
	"database/sql"
	"path/filepath"
	"testing"
)

//nolint:cyclop // test complexity justified by pairing flow coverage
func TestPairingStore_Lifecycle(t *testing.T) {
	t.Parallel()
	tmp := t.TempDir()
	dbPath := filepath.Join(tmp, "pairing.db")

	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("failed to open db: %v", err)
	}
	defer func() { _ = db.Close() }()

	store, err := NewPairingStore(db)
	if err != nil {
		t.Fatalf("NewPairingStore: %v", err)
	}

	chatID := int64(12345)

	// 1. Initially not authorized.
	auth, err := store.IsAuthorized(chatID)
	if err != nil {
		t.Fatalf("IsAuthorized: %v", err)
	}
	if auth {
		t.Error("expected unauthorized, got authorized")
	}

	// 2. Generate code.
	code, err := store.GetOrCreateCode(chatID)
	if err != nil {
		t.Fatalf("GetOrCreateCode: %v", err)
	}
	if len(code) != 6 {
		t.Errorf("expected 6-digit code, got %q", code)
	}

	// 3. Authorize via code.
	authorizedID, err := store.AuthorizeByCode(code)
	if err != nil {
		t.Fatalf("AuthorizeByCode: %v", err)
	}
	if authorizedID != chatID {
		t.Errorf("expected authorizedID %d, got %d", chatID, authorizedID)
	}

	// 4. Verify authorized.
	auth, err = store.IsAuthorized(chatID)
	if err != nil {
		t.Fatalf("IsAuthorized (after): %v", err)
	}
	if !auth {
		t.Error("expected authorized, got unauthorized")
	}
}

func TestPairingStore_DirectAuthorize(t *testing.T) {
	t.Parallel()
	tmp := t.TempDir()
	dbPath := filepath.Join(tmp, "pairing.db")

	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("failed to open db: %v", err)
	}
	defer func() { _ = db.Close() }()

	store, err := NewPairingStore(db)
	if err != nil {
		t.Fatalf("NewPairingStore: %v", err)
	}

	chatID := int64(99999)
	if err := store.AuthorizeByChatID(chatID, "admin"); err != nil {
		t.Fatalf("AuthorizeByChatID: %v", err)
	}

	auth, _ := store.IsAuthorized(chatID)
	if !auth {
		t.Error("expected authorized after DirectAuthorize")
	}
}

func TestPairingStore_MigrationCompat(t *testing.T) {
	t.Parallel()
	tmp := t.TempDir()
	dbPath := filepath.Join(tmp, "pairing.db")

	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("failed to open db: %v", err)
	}
	// Do not defer Close() yet as we need to reopen.

	// Pre-create table with old schema (missing authorized_by).
	_, err = db.ExecContext(stdctx.Background(), `CREATE TABLE authorized_users (chat_id INTEGER PRIMARY KEY)`)
	if err != nil {
		_ = db.Close()
		t.Fatalf("failed to create legacy table: %v", err)
	}

	_, err = db.ExecContext(stdctx.Background(), `INSERT INTO authorized_users (chat_id) VALUES (?)`, int64(99999))
	if err != nil {
		_ = db.Close()
		t.Fatalf("insert authorized_user: %v", err)
	}
	_ = db.Close()

	// Reopen via Store (triggers Schema check/update).
	db2, _ := sql.Open("sqlite", dbPath)
	defer func() { _ = db2.Close() }()

	store, err := NewPairingStore(db2)
	if err != nil {
		t.Fatalf("NewPairingStore after legacy setup: %v", err)
	}

	auth, _ := store.IsAuthorized(99999)
	if !auth {
		t.Error("expected data to survive migration")
	}
}
