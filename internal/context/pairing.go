package context

import (
	stdctx "context"
	"crypto/rand"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"math/big"
)

// PairingStore manages authorized users and pairing codes in SQLite.
type PairingStore struct {
	db *sql.DB
}

// NewPairingStore creates a PairingStore backed by db and initializes its schema.
// db must already be open and have WAL mode set (done by openDB).
func NewPairingStore(db *sql.DB) (*PairingStore, error) {
	if err := initPairingSchema(db); err != nil {
		return nil, err
	}
	return &PairingStore{db: db}, nil
}

func initPairingSchema(db *sql.DB) error {
	_, err := db.ExecContext(stdctx.Background(), `
CREATE TABLE IF NOT EXISTS authorized_users (
    chat_id       INTEGER PRIMARY KEY,
    authorized_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    authorized_by TEXT     DEFAULT ''
);

CREATE TABLE IF NOT EXISTS pairing_codes (
    code       TEXT    PRIMARY KEY,
    chat_id    INTEGER NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    expires_at DATETIME NOT NULL
);
`)
	return err
}

// IsAuthorized returns true if chatID exists in authorized_users.
func (s *PairingStore) IsAuthorized(chatID int64) (bool, error) {
	var count int
	err := s.db.QueryRowContext(
		stdctx.Background(),
		`SELECT COUNT(*) FROM authorized_users WHERE chat_id = ?`, chatID,
	).Scan(&count)
	if err != nil {
		return false, err
	}
	return count > 0, nil
}

// GetOrCreateCode returns a non-expired pairing code for chatID, creating one if needed.
func (s *PairingStore) GetOrCreateCode(chatID int64) (string, error) {
	var code string
	err := s.db.QueryRowContext(
		stdctx.Background(),
		`SELECT code FROM pairing_codes WHERE chat_id = ? AND expires_at > datetime('now') LIMIT 1`,
		chatID,
	).Scan(&code)
	if err == nil {
		return code, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return "", err
	}

	// Delete expired codes for this chatID.
	if _, err := s.db.ExecContext(
		stdctx.Background(),
		`DELETE FROM pairing_codes WHERE chat_id = ? AND expires_at <= datetime('now')`,
		chatID,
	); err != nil {
		return "", err
	}

	nBig, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
	if err != nil {
		return "", fmt.Errorf("pairing: generate code: %w", err)
	}
	newCode := fmt.Sprintf("%06d", nBig.Int64())

	if _, err := s.db.ExecContext(
		stdctx.Background(),
		`INSERT INTO pairing_codes (code, chat_id, expires_at) VALUES (?, ?, datetime('now', '+24 hours'))`,
		newCode, chatID,
	); err != nil {
		return "", err
	}

	return newCode, nil
}

// AuthorizeByCode looks up a valid pairing code, authorizes the associated chat,
// deletes the code, and returns the chatID.
func (s *PairingStore) AuthorizeByCode(code string) (int64, error) {
	var chatID int64
	err := s.db.QueryRowContext(
		stdctx.Background(),
		`SELECT chat_id FROM pairing_codes WHERE code = ? AND expires_at > datetime('now')`,
		code,
	).Scan(&chatID)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, fmt.Errorf("pairing: code %q not found or expired", code)
	}
	if err != nil {
		return 0, err
	}

	if _, err := s.db.ExecContext(
		stdctx.Background(),
		`INSERT OR REPLACE INTO authorized_users (chat_id) VALUES (?)`,
		chatID,
	); err != nil {
		return 0, err
	}

	if _, err := s.db.ExecContext(
		stdctx.Background(),
		`DELETE FROM pairing_codes WHERE code = ?`,
		code,
	); err != nil {
		slog.Warn("pairing: failed to delete used code", "code", code, "err", err)
	}

	return chatID, nil
}

// AuthorizeByChatID directly authorizes a chatID, recording who authorized it.
func (s *PairingStore) AuthorizeByChatID(chatID int64, by string) error {
	_, err := s.db.ExecContext(
		stdctx.Background(),
		`INSERT OR REPLACE INTO authorized_users (chat_id, authorized_by) VALUES (?, ?)`,
		chatID, by,
	)
	return err
}
