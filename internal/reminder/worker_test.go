//nolint:testpackage // Injects a clock and transaction faults without production fault hooks.
package reminder

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"strings"
	"testing"
	"time"
)

func testWorker(s *Store, now *time.Time) *Worker {
	return &Worker{
		Store: s, now: func() time.Time { return *now },
		Authorize: func(context.Context, Owner) (bool, error) { return true, nil },
		Send:      func(context.Context, Reminder) error { return nil },
		Transient: func(error) bool { return true },
	}
}

func stepWorker(t *testing.T, w *Worker, now time.Time, want bool) {
	t.Helper()
	worked, err := w.step(context.Background(), now)
	if err != nil || worked != want {
		t.Fatalf("worker step worked=%v want=%v err=%v", worked, want, err)
	}
}

//nolint:gocognit,cyclop // Three attempts and two restarts verify one persisted delivery history.
func TestWorkerRetryRestartAndSafeLogs(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	s := openTestStore(t, root)
	now, owner := time.Now().Truncate(time.Millisecond), (Owner{-100, 17})
	r := createTestReminder(t, s, owner, 42, now)
	now = now.Add(time.Hour)
	var logs bytes.Buffer
	w := testWorker(s, &now)
	w.Logger = slog.New(slog.NewJSONHandler(&logs, nil))
	sends := 0
	w.Send = func(ctx context.Context, got Reminder) error {
		sends++
		if _, ok := ctx.Deadline(); !ok || got.Text != r.Text || got.TopicID != 42 || got.Owner != owner {
			t.Error("send missing deadline or original text/destination")
		}
		return errors.New("remote error containing " + r.Text)
	}
	for attempt, delay := range []time.Duration{time.Minute, 5 * time.Minute, 5 * time.Minute} {
		stepWorker(t, w, now, true)
		rows := listTestReminders(t, s, owner)
		if rows[0].Attempts != attempt+1 || !rows[0].NextAttempt.Equal(now.Add(delay)) {
			t.Fatalf("attempt or backoff not persisted: %+v", rows)
		}
		if attempt == 2 {
			if rows[0].State != Failed || rows[0].Failure != "attempts_exhausted" {
				t.Fatalf("exhausted failure invisible: %+v", rows)
			}
			break
		}
		if err := s.Close(); err != nil {
			t.Fatal(err)
		}
		s = openTestStore(t, root)
		w.Store = s
		if err := s.Recover(context.Background(), now); err != nil {
			t.Fatal(err)
		}
		stepWorker(t, w, now.Add(delay-time.Millisecond), false)
		now = now.Add(delay)
	}
	stepWorker(t, w, now.Add(24*time.Hour), false)
	if sends != 3 || strings.Contains(logs.String(), r.Text) || !strings.Contains(logs.String(), "attempts_exhausted") {
		t.Fatalf("incorrect attempts or unsafe logs: sends=%d logs=%s", sends, logs.String())
	}
}

func TestWorkerAuthorizationFailure(t *testing.T) {
	t.Parallel()
	for _, lookupErr := range []error{nil, errors.New("lookup failed")} {
		t.Run("denied "+errorText(lookupErr), func(t *testing.T) {
			t.Parallel()
			s := openTestStore(t, t.TempDir())
			now, owner := time.Now(), (Owner{123, 17})
			createTestReminder(t, s, owner, 0, now)
			now = now.Add(time.Hour)
			w := testWorker(s, &now)
			w.Authorize = func(context.Context, Owner) (bool, error) { return false, lookupErr }
			w.Send = func(context.Context, Reminder) error { t.Error("unauthorized send"); return nil }
			stepWorker(t, w, now, true)
			if rows := listTestReminders(t, s, owner); rows[0].State != Failed || rows[0].Failure != "authorization_failed" {
				t.Fatalf("authorization failure not visible: %+v", rows)
			}
		})
	}
}

func errorText(err error) string {
	if err != nil {
		return err.Error()
	}
	return "revoked"
}

//nolint:gocognit // Exercises both sides of the claim boundary without timing sleeps.
func TestCancellationBeforeAndAfterClaim(t *testing.T) {
	t.Parallel()
	for _, before := range []bool{true, false} {
		t.Run(map[bool]string{true: "before", false: "after"}[before], func(t *testing.T) {
			t.Parallel()
			s := openTestStore(t, t.TempDir())
			now, owner := time.Now(), (Owner{123, 17})
			r := createTestReminder(t, s, owner, 0, now)
			now = now.Add(time.Hour)
			w := testWorker(s, &now)
			if before {
				if state, err := s.Cancel(context.Background(), owner, r.ID, now); err != nil || state != Cancelled {
					t.Fatalf("cancel before claim: %s %v", state, err)
				}
				w.Send = func(context.Context, Reminder) error { t.Error("cancelled reminder sent"); return nil }
				stepWorker(t, w, now, false)
				return
			}
			w.Send = func(context.Context, Reminder) error {
				state, err := s.Cancel(context.Background(), owner, r.ID, now)
				if err != nil || state != Dispatching {
					t.Errorf("cancel after claim: %s %v", state, err)
				}
				return nil
			}
			stepWorker(t, w, now, true)
			if listTestReminders(t, s, owner)[0].State != Delivered {
				t.Fatal("claimed delivery was incorrectly cancelled")
			}
		})
	}
}

func TestInterruptedDispatchRecovery(t *testing.T) {
	t.Parallel()
	s := openTestStore(t, t.TempDir())
	now, owner := time.Now().Truncate(time.Millisecond), (Owner{123, 17})
	createTestReminder(t, s, owner, 0, now)
	now = now.Add(time.Hour)
	for attempt := 1; attempt <= 3; attempt++ {
		claimed, found, err := s.Claim(context.Background(), now)
		if err != nil || !found || claimed.Attempts != attempt {
			t.Fatalf("claim %d: %+v %v %v", attempt, claimed, found, err)
		}
		if err := s.Recover(context.Background(), now); err != nil {
			t.Fatal(err)
		}
		rows := listTestReminders(t, s, owner)
		if rows[0].Attempts != attempt || !rows[0].NextAttempt.Equal(claimed.NextAttempt) {
			t.Fatalf("recovery lost attempt/backoff: %+v", rows)
		}
		now = claimed.NextAttempt
	}
	if listTestReminders(t, s, owner)[0].State != Failed {
		t.Fatal("repeated interrupted dispatches did not exhaust budget")
	}
}

func TestAcceptedSendBeforeCommitCanDuplicate(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	s := openTestStore(t, root)
	now, owner := time.Now().Truncate(time.Millisecond), (Owner{123, 17})
	createTestReminder(t, s, owner, 0, now)
	now = now.Add(time.Hour)
	w, sends := testWorker(s, &now), 0
	w.Send = func(context.Context, Reminder) error { sends++; return nil }
	execTestSQL(t, s, `CREATE TRIGGER fail_finish BEFORE UPDATE ON reminders WHEN NEW.state='delivered' BEGIN SELECT RAISE(ABORT,'commit failed'); END`)
	if _, err := w.step(context.Background(), now); err == nil || sends != 1 {
		t.Fatalf("send/commit fault not exercised: sends=%d err=%v", sends, err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	s = openTestStore(t, root)
	w.Store = s
	execTestSQL(t, s, "DROP TRIGGER fail_finish")
	if err := s.Recover(context.Background(), now); err != nil {
		t.Fatal(err)
	}
	now = now.Add(time.Minute)
	stepWorker(t, w, now, true)
	if sends != 2 || listTestReminders(t, s, owner)[0].State != Delivered {
		t.Fatal("uncertain acceptance must recover, with documented duplicate possibility")
	}
}

func TestRunCancellationJoinsBlockedSend(t *testing.T) {
	t.Parallel()
	s := openTestStore(t, t.TempDir())
	now := time.Now().Add(-time.Hour)
	owner := Owner{123, 17}
	createTestReminder(t, s, owner, 0, now)
	w := testWorker(s, &now)
	w.now = nil
	entered, exited := make(chan struct{}), make(chan struct{})
	w.Send = func(ctx context.Context, _ Reminder) error {
		close(entered)
		<-ctx.Done()
		close(exited)
		return ctx.Err()
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- w.Run(ctx) }()
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		t.Fatal("overdue reminder was not delivered promptly")
	}
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("worker did not join cancelled send")
	}
	<-exited
	if rows := listTestReminders(t, s, owner); rows[0].State != Pending || rows[0].Attempts != 1 {
		t.Fatalf("shutdown lost retry progress: %+v", rows)
	}
}
