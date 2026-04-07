package context

import (
	"database/sql"
	"path/filepath"
	"testing"
	"unicode"

	_ "modernc.org/sqlite"
)

func newTestPairingDB(t *testing.T) *sql.DB {
	t.Helper()
	dir := t.TempDir()
	db, err := sql.Open("sqlite", filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

func TestPairingStore_IsAuthorized_False(t *testing.T) {
	t.Parallel()
	db := newTestPairingDB(t)
	store, err := NewPairingStore(db)
	if err != nil {
		t.Fatalf("NewPairingStore: %v", err)
	}

	got, err := store.IsAuthorized(12345)
	if err != nil {
		t.Fatalf("IsAuthorized: %v", err)
	}
	if got {
		t.Error("expected false for unknown chatID, got true")
	}
}

func TestPairingStore_IsAuthorized_True(t *testing.T) {
	t.Parallel()
	db := newTestPairingDB(t)
	store, err := NewPairingStore(db)
	if err != nil {
		t.Fatalf("NewPairingStore: %v", err)
	}

	_, err = db.Exec(`INSERT INTO authorized_users (chat_id) VALUES (?)`, int64(99999))
	if err != nil {
		t.Fatalf("insert authorized_user: %v", err)
	}

	got, err := store.IsAuthorized(99999)
	if err != nil {
		t.Fatalf("IsAuthorized: %v", err)
	}
	if !got {
		t.Error("expected true for inserted chatID, got false")
	}
}

func TestPairingStore_GetOrCreateCode_CreatesCode(t *testing.T) {
	t.Parallel()
	db := newTestPairingDB(t)
	store, err := NewPairingStore(db)
	if err != nil {
		t.Fatalf("NewPairingStore: %v", err)
	}

	code, err := store.GetOrCreateCode(11111)
	if err != nil {
		t.Fatalf("GetOrCreateCode: %v", err)
	}
	if len(code) != 6 {
		t.Errorf("expected 6-char code, got %q (len %d)", code, len(code))
	}
	for _, ch := range code {
		if !unicode.IsDigit(ch) {
			t.Errorf("expected all digits in code, got %q", code)
			break
		}
	}
}

func TestPairingStore_GetOrCreateCode_ReturnsExistingCode(t *testing.T) {
	t.Parallel()
	db := newTestPairingDB(t)
	store, err := NewPairingStore(db)
	if err != nil {
		t.Fatalf("NewPairingStore: %v", err)
	}

	first, err := store.GetOrCreateCode(22222)
	if err != nil {
		t.Fatalf("GetOrCreateCode (first): %v", err)
	}
	second, err := store.GetOrCreateCode(22222)
	if err != nil {
		t.Fatalf("GetOrCreateCode (second): %v", err)
	}
	if first != second {
		t.Errorf("expected same code on second call; first=%q second=%q", first, second)
	}
}

func TestPairingStore_AuthorizeByCode_Success(t *testing.T) {
	t.Parallel()
	db := newTestPairingDB(t)
	store, err := NewPairingStore(db)
	if err != nil {
		t.Fatalf("NewPairingStore: %v", err)
	}

	const chatID int64 = 33333
	code, err := store.GetOrCreateCode(chatID)
	if err != nil {
		t.Fatalf("GetOrCreateCode: %v", err)
	}

	gotID, err := store.AuthorizeByCode(code)
	if err != nil {
		t.Fatalf("AuthorizeByCode: %v", err)
	}
	if gotID != chatID {
		t.Errorf("expected chatID %d, got %d", chatID, gotID)
	}

	authorized, err := store.IsAuthorized(chatID)
	if err != nil {
		t.Fatalf("IsAuthorized: %v", err)
	}
	if !authorized {
		t.Error("expected chatID to be authorized after AuthorizeByCode")
	}
}

func TestPairingStore_AuthorizeByCode_NotFound(t *testing.T) {
	t.Parallel()
	db := newTestPairingDB(t)
	store, err := NewPairingStore(db)
	if err != nil {
		t.Fatalf("NewPairingStore: %v", err)
	}

	_, err = store.AuthorizeByCode("000000")
	if err == nil {
		t.Fatal("expected error for bogus code, got nil")
	}
}

func TestPairingStore_AuthorizeByChatID(t *testing.T) {
	t.Parallel()
	db := newTestPairingDB(t)
	store, err := NewPairingStore(db)
	if err != nil {
		t.Fatalf("NewPairingStore: %v", err)
	}

	const chatID int64 = 44444
	if err := store.AuthorizeByChatID(chatID, "operator"); err != nil {
		t.Fatalf("AuthorizeByChatID: %v", err)
	}

	authorized, err := store.IsAuthorized(chatID)
	if err != nil {
		t.Fatalf("IsAuthorized: %v", err)
	}
	if !authorized {
		t.Error("expected chatID to be authorized after AuthorizeByChatID")
	}
}

func TestPairingStore_AuthorizeByCode_DeletesCode(t *testing.T) {
	t.Parallel()
	db := newTestPairingDB(t)
	store, err := NewPairingStore(db)
	if err != nil {
		t.Fatalf("NewPairingStore: %v", err)
	}

	const chatID int64 = 55555
	code, err := store.GetOrCreateCode(chatID)
	if err != nil {
		t.Fatalf("GetOrCreateCode: %v", err)
	}

	if _, err := store.AuthorizeByCode(code); err != nil {
		t.Fatalf("AuthorizeByCode (first): %v", err)
	}

	_, err = store.AuthorizeByCode(code)
	if err == nil {
		t.Fatal("expected error on second use of same code, got nil")
	}
}
