package audit

import (
	"crypto/sha256"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite" // register "sqlite" driver
)

const auditDBFileName = "audit.db"

// AuditEntry is one side-effect event to record.
//
// revive:disable:exported
type AuditEntry struct {
	SessionID string
	Actor     string // "agent" or "user"
	Action    string // tool call name or event type
	Result    string // result/output (may be pre-truncated by the caller)
}

// AuditRecord is a persisted entry including hash chain fields.
//
// revive:disable:exported
type AuditRecord struct {
	ID        int64
	Timestamp string
	SessionID string
	Actor     string
	Action    string
	Result    string
	PrevHash  string
	Hash      string
}

// AuditLedger is an append-only SQLite-backed audit log with a SHA-256 hash chain.
// Create via NewAuditLedger; close via Close when done.
//
// revive:disable:exported
type AuditLedger struct {
	db *sql.DB
}

// NewAuditLedger opens (or creates) the audit ledger at
// {storageRoot}/workspace/audit.db with WAL mode enabled.
func NewAuditLedger(storageRoot string) (*AuditLedger, error) {
	dir := filepath.Join(storageRoot, "workspace")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("audit ledger: create dir: %w", err)
	}
	dbPath := filepath.Join(dir, auditDBFileName)
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return nil, fmt.Errorf("audit ledger: open db: %w", err)
	}
	if _, err := db.Exec("PRAGMA journal_mode=WAL"); err != nil {
		db.Close()
		return nil, fmt.Errorf("audit ledger: WAL mode: %w", err)
	}
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	if err := initAuditSchema(db); err != nil {
		db.Close()
		return nil, err
	}
	return &AuditLedger{db: db}, nil
}

func initAuditSchema(db *sql.DB) error {
	_, err := db.Exec(`
		CREATE TABLE IF NOT EXISTS audit_log (
			id         INTEGER PRIMARY KEY AUTOINCREMENT,
			timestamp  TEXT    NOT NULL,
			session_id TEXT    NOT NULL,
			actor      TEXT    NOT NULL,
			action     TEXT    NOT NULL,
			result     TEXT    NOT NULL DEFAULT '',
			prev_hash  TEXT    NOT NULL DEFAULT '',
			hash       TEXT    NOT NULL
		)
	`)
	if err != nil {
		return fmt.Errorf("audit ledger: create table: %w", err)
	}
	return nil
}

// Close closes the underlying database connection.
func (l *AuditLedger) Close() error { return l.db.Close() }

// Append records a new audit entry, chaining it to the previous record's hash.
func (l *AuditLedger) Append(entry AuditEntry) error {
	var prevHash string
	row := l.db.QueryRow(`SELECT hash FROM audit_log ORDER BY id DESC LIMIT 1`)
	_ = row.Scan(&prevHash) // ignore sql.ErrNoRows — prevHash stays ""

	ts := time.Now().UTC().Format(time.RFC3339Nano)
	hash := auditHash(prevHash, ts, entry.SessionID, entry.Actor, entry.Action, entry.Result)

	_, err := l.db.Exec(
		`INSERT INTO audit_log (timestamp, session_id, actor, action, result, prev_hash, hash)
		 VALUES (?, ?, ?, ?, ?, ?, ?)`,
		ts, entry.SessionID, entry.Actor, entry.Action, entry.Result, prevHash, hash,
	)
	if err != nil {
		return fmt.Errorf("audit: append: %w", err)
	}
	return nil
}

// GetAll returns all audit records in ascending insertion order.
func (l *AuditLedger) GetAll() ([]AuditRecord, error) {
	rows, err := l.db.Query(
		`SELECT id, timestamp, session_id, actor, action, result, prev_hash, hash
		 FROM audit_log ORDER BY id ASC`)
	if err != nil {
		return nil, fmt.Errorf("audit: get all: %w", err)
	}
	defer rows.Close()

	var records []AuditRecord
	for rows.Next() {
		var r AuditRecord
		if err := rows.Scan(&r.ID, &r.Timestamp, &r.SessionID, &r.Actor, &r.Action,
			&r.Result, &r.PrevHash, &r.Hash); err != nil {
			return nil, fmt.Errorf("audit: scan: %w", err)
		}
		records = append(records, r)
	}
	return records, rows.Err()
}

// Verify walks the entire chain and returns a non-nil error if any record's
// hash is wrong or the prev_hash links are broken.
func (l *AuditLedger) Verify() error {
	records, err := l.GetAll()
	if err != nil {
		return err
	}
	for i, r := range records {
		expected := auditHash(r.PrevHash, r.Timestamp, r.SessionID, r.Actor, r.Action, r.Result)
		if r.Hash != expected {
			return fmt.Errorf("audit: hash mismatch at record index %d (id=%d)", i, r.ID)
		}
		if i > 0 && r.PrevHash != records[i-1].Hash {
			return fmt.Errorf("audit: broken chain at record index %d (id=%d)", i, r.ID)
		}
	}
	return nil
}

// auditHash returns the SHA-256 hex digest of the pipe-delimited fields.
func auditHash(prevHash, timestamp, sessionID, actor, action, result string) string {
	h := sha256.New()
	fmt.Fprintf(h, "%s|%s|%s|%s|%s|%s", prevHash, timestamp, sessionID, actor, action, result)
	return fmt.Sprintf("%x", h.Sum(nil))
}
