package reminder

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// Recover requeues abandoned dispatches, retaining their attempt count and backoff.
// Call only at worker startup; a send accepted before a crash may be duplicated.
func (s *Store) Recover(ctx context.Context, now time.Time) error {
	_, err := s.db.ExecContext(ctx, `UPDATE reminders SET
 state=CASE WHEN attempts>=3 THEN 'failed' ELSE 'pending' END,
 finished_ms=CASE WHEN attempts>=3 THEN ? ELSE NULL END,
 failure=CASE WHEN attempts>=3 THEN 'attempts_exhausted' ELSE 'interrupted' END
 WHERE state='dispatching'`, now.UnixMilli())
	if err != nil {
		return fmt.Errorf("reminder recover: %w", err)
	}
	return nil
}

// Claim atomically reserves one due reminder and budgets a send attempt.
func (s *Store) Claim(ctx context.Context, now time.Time) (Reminder, bool, error) {
	r, err := scanReminder(s.db.QueryRowContext(ctx, `UPDATE reminders SET state='dispatching',
 attempts=attempts+1, next_ms=? + CASE WHEN attempts=0 THEN 60000 ELSE 300000 END
 WHERE id=(SELECT id FROM reminders WHERE state='pending' AND next_ms<=? AND due_ms<=? AND attempts<3 ORDER BY next_ms,id LIMIT 1)
 AND state='pending' RETURNING `+reminderColumns, now.UnixMilli(), now.UnixMilli(), now.UnixMilli()))
	if errors.Is(err, sql.ErrNoRows) {
		return Reminder{}, false, nil
	}
	if err != nil {
		return Reminder{}, false, fmt.Errorf("reminder claim: %w", err)
	}
	return r, true, nil
}

// Finish commits the result of a claimed attempt. failure is a safe code, never remote text.
func (s *Store) Finish(ctx context.Context, r Reminder, state State, failure string, now time.Time) error {
	if state != Pending && state != Delivered && state != Failed {
		return errors.New("reminder: invalid finish state")
	}
	var finished any
	if state != Pending {
		finished = now.UnixMilli()
	}
	// Backoff starts when the attempt ends, even when the network call took time.
	result, err := s.db.ExecContext(ctx, `UPDATE reminders SET state=?,failure=?,finished_ms=?,next_ms=? WHERE id=? AND state='dispatching' AND attempts=?`,
		state, failure, finished, now.Add(retryDelay(r.Attempts)).UnixMilli(), r.ID, r.Attempts)
	if err != nil {
		return fmt.Errorf("reminder finish: %w", err)
	}
	count, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("reminder finish affected rows: %w", err)
	}
	if count != 1 {
		return errors.New("reminder: claimed record changed before finish")
	}
	return nil
}

// Prune removes only terminal records older than 30 days.
func (s *Store) Prune(ctx context.Context, now time.Time) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM reminders WHERE state IN ('delivered','cancelled','failed') AND finished_ms<?`, now.Add(-30*24*time.Hour).UnixMilli())
	if err != nil {
		return fmt.Errorf("reminder prune: %w", err)
	}
	return nil
}
