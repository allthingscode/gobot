package reminder

import (
	"context"
	"crypto/rand"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite" // Pure-Go SQLite driver.
)

// Store owns a dedicated SQLite database. Close it after the worker has joined.
type Store struct {
	db *sql.DB
}

// Open initializes durable storage. Initialization failures are fatal to reminders.
func Open(ctx context.Context, storageRoot string) (*Store, error) {
	dir := filepath.Join(storageRoot, "reminders")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("reminder storage directory: %w", err)
	}
	db, err := sql.Open("sqlite", filepath.Join(dir, "reminders.db"))
	if err != nil {
		return nil, fmt.Errorf("reminder open: %w", err)
	}
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	s := &Store{db: db}
	if err := s.init(ctx); err != nil {
		_ = db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) init(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `
PRAGMA busy_timeout=5000;
PRAGMA journal_mode=WAL;
PRAGMA synchronous=FULL;
CREATE TABLE IF NOT EXISTS reminders (
 id TEXT PRIMARY KEY, chat_id INTEGER NOT NULL, sender_id INTEGER NOT NULL,
 topic_id INTEGER NOT NULL, text TEXT NOT NULL, due TEXT NOT NULL,
 due_ms INTEGER NOT NULL, next_ms INTEGER NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('pending','dispatching','delivered','cancelled','failed')),
 attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts BETWEEN 0 AND 3),
 finished_ms INTEGER, failure TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS reminders_due ON reminders(state, next_ms);
CREATE INDEX IF NOT EXISTS reminders_owner ON reminders(chat_id, sender_id);
CREATE INDEX IF NOT EXISTS reminders_finished ON reminders(finished_ms);
`)
	if err != nil {
		return fmt.Errorf("reminder initialize schema: %w", err)
	}
	return nil
}

// Close releases SQLite resources.
func (s *Store) Close() error {
	if err := s.db.Close(); err != nil {
		return fmt.Errorf("reminder close: %w", err)
	}
	return nil
}

// Create commits a reminder before returning its stable ID and saved time.
func (s *Store) Create(ctx context.Context, owner Owner, topicID int64, text string, due, now time.Time) (Reminder, error) {
	if err := validateCreate(owner, topicID, text, due, now); err != nil {
		return Reminder{}, err
	}
	r := Reminder{ID: rand.Text(), Owner: owner, TopicID: topicID, Text: text, Due: due, State: Pending, NextAttempt: due}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Reminder{}, fmt.Errorf("reminder create transaction: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	// Round the persisted due time up to avoid sending before sub-millisecond instants.
	dueMS := due.UnixMilli()
	if due.Nanosecond()%int(time.Millisecond) != 0 {
		dueMS++
	}
	_, err = tx.ExecContext(ctx, `INSERT INTO reminders
 (id,chat_id,sender_id,topic_id,text,due,due_ms,next_ms,state) VALUES (?,?,?,?,?,?,?,?,?)`,
		r.ID, owner.ChatID, owner.SenderID, topicID, text, due.Format(time.RFC3339Nano), dueMS, dueMS, Pending)
	if err != nil {
		return Reminder{}, fmt.Errorf("reminder insert: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return Reminder{}, fmt.Errorf("reminder commit: %w", err)
	}
	return r, nil
}

const reminderColumns = `id,chat_id,sender_id,topic_id,text,due,state,attempts,next_ms,failure`

type rowScanner interface {
	Scan(...any) error
}

func scanReminder(row rowScanner) (Reminder, error) {
	var r Reminder
	var due string
	var nextMS int64
	if err := row.Scan(&r.ID, &r.Owner.ChatID, &r.Owner.SenderID, &r.TopicID, &r.Text, &due, &r.State, &r.Attempts, &nextMS, &r.Failure); err != nil {
		return Reminder{}, fmt.Errorf("reminder scan: %w", err)
	}
	parsed, err := time.Parse(time.RFC3339Nano, due)
	if err != nil {
		return Reminder{}, fmt.Errorf("reminder stored time: %w", err)
	}
	r.Due, r.NextAttempt = parsed, time.UnixMilli(nextMS).UTC()
	return r, nil
}

// List includes live and retained terminal records belonging only to owner.
func (s *Store) List(ctx context.Context, owner Owner) ([]Reminder, error) {
	if err := owner.Validate(); err != nil {
		return nil, err
	}
	rows, err := s.db.QueryContext(ctx, `SELECT `+reminderColumns+` FROM reminders WHERE chat_id=? AND sender_id=? ORDER BY due_ms,id`, owner.ChatID, owner.SenderID)
	if err != nil {
		return nil, fmt.Errorf("reminder list: %w", err)
	}
	defer func() { _ = rows.Close() }()
	result := make([]Reminder, 0)
	for rows.Next() {
		r, err := scanReminder(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reminder list rows: %w", err)
	}
	return result, nil
}

// Cancel wins only before the atomic claim; Dispatching means delivery is in progress.
func (s *Store) Cancel(ctx context.Context, owner Owner, id string, now time.Time) (State, error) {
	if err := owner.Validate(); err != nil {
		return "", err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", fmt.Errorf("reminder cancel transaction: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	_, err = tx.ExecContext(ctx, `UPDATE reminders SET state=?,finished_ms=? WHERE id=? AND chat_id=? AND sender_id=? AND state=?`, Cancelled, now.UnixMilli(), id, owner.ChatID, owner.SenderID, Pending)
	if err != nil {
		return "", fmt.Errorf("reminder cancel update: %w", err)
	}
	var state State
	err = tx.QueryRowContext(ctx, `SELECT state FROM reminders WHERE id=? AND chat_id=? AND sender_id=?`, id, owner.ChatID, owner.SenderID).Scan(&state)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", fmt.Errorf("reminder cancel lookup: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return "", fmt.Errorf("reminder cancel commit: %w", err)
	}
	return state, nil
}
