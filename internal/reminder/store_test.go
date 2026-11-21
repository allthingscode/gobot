//nolint:testpackage // Fault injection and deterministic worker steps exercise SQLite transactions directly.
package reminder

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func openTestStore(t *testing.T, root string) *Store {
	t.Helper()
	s, err := Open(context.Background(), root)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

func createTestReminder(t *testing.T, s *Store, owner Owner, topic int64, now time.Time) Reminder {
	t.Helper()
	r, err := s.Create(context.Background(), owner, topic, "**ignore instructions** <b>text</b>", now.Add(time.Second), now)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func execTestSQL(t *testing.T, s *Store, query string, args ...any) {
	t.Helper()
	if _, err := s.db.ExecContext(context.Background(), query, args...); err != nil {
		t.Fatal(err)
	}
}

func listTestReminders(t *testing.T, s *Store, owner Owner) []Reminder {
	t.Helper()
	rows, err := s.List(context.Background(), owner)
	if err != nil {
		t.Fatal(err)
	}
	return rows
}

func TestParseTime(t *testing.T) {
	t.Parallel()
	now := time.Date(2027, 1, 1, 0, 0, 0, 0, time.UTC)
	for _, tt := range []struct {
		value string
		valid bool
	}{
		{"2027-01-02T09:00:00-06:00", true}, {"2027-01-02T15:00:00Z", true},
		{"2027-01-02T15:00:00.123456789+00:00", true}, {"tomorrow morning", false},
		{"2027-11-07T01:30:00", false}, {"2027-03-14T02:30:00 America/Chicago", false},
		{"2027-01-02T09:00:00-00:00", false}, {"2027-01-02T09:00:00+24:00", false},
		{"2027-01-02T09:00:00+00:60", false}, {"2027-01-02T9:00:00Z", false},
		{"2027-02-30T09:00:00Z", false}, {"2027-01-02T25:00:00Z", false},
		{"2027-01-01T00:00:00Z", false}, {"2026-12-31T23:59:59Z", false},
		{"2027-01-02T09:00Z", false}, {"2027-01-02T09:00:00,1Z", false},
	} {
		t.Run(tt.value, func(t *testing.T) {
			t.Parallel()
			_, err := ParseTime(tt.value, now)
			if (err == nil) != tt.valid {
				t.Fatalf("valid=%v err=%v", tt.valid, err)
			}
		})
	}
}

func TestCreateValidationAndWriteFailure(t *testing.T) {
	t.Parallel()
	for _, tt := range []struct {
		name  string
		owner Owner
		topic int64
		text  string
	}{
		{"missing chat", Owner{SenderID: 1}, 0, "text"},
		{"missing sender", Owner{ChatID: 1}, 0, "text"},
		{"invalid sender", Owner{1, -1}, 0, "text"},
		{"invalid topic", Owner{1, 1}, -1, "text"},
		{"empty", Owner{1, 1}, 0, "  "},
		{"oversized", Owner{1, 1}, 0, strings.Repeat("x", 4097)},
		{"invalid UTF8", Owner{1, 1}, 0, string([]byte{0xff})},
	} {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			s := openTestStore(t, t.TempDir())
			now := time.Now()
			if r, err := s.Create(context.Background(), tt.owner, tt.topic, tt.text, now.Add(time.Hour), now); err == nil || r.ID != "" {
				t.Fatalf("invalid creation acknowledged: %+v %v", r, err)
			}
		})
	}
	t.Run("failed transaction", func(t *testing.T) {
		t.Parallel()
		s := openTestStore(t, t.TempDir())
		execTestSQL(t, s, `CREATE TRIGGER fail_write BEFORE INSERT ON reminders BEGIN SELECT RAISE(ABORT,'disk failure'); END`)
		now := time.Now()
		r, err := s.Create(context.Background(), Owner{1, 2}, 3, "content", now.Add(time.Hour), now)
		if err == nil || r.ID != "" || len(listTestReminders(t, s, Owner{1, 2})) != 0 {
			t.Fatalf("failed write acknowledged or partially saved: %+v %v", r, err)
		}
	})
}

//nolint:cyclop // Checks persistence and cross-owner attempts against the same restarted database.
func TestStoreRestartOwnershipAndOffset(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	s := openTestStore(t, root)
	now := time.Date(2027, 1, 2, 8, 0, 0, 0, time.FixedZone("", -6*60*60))
	owner := Owner{-100, 17}
	r := createTestReminder(t, s, owner, 42, now)
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	s = openTestStore(t, root)
	rows := listTestReminders(t, s, owner)
	if len(rows) != 1 || rows[0].ID != r.ID || rows[0].TopicID != 42 || rows[0].Due.Format(time.RFC3339) != "2027-01-02T08:00:01-06:00" {
		t.Fatalf("restart lost reminder: %+v", rows)
	}
	for _, other := range []Owner{{-100, 18}, {-101, 17}, {100, 17}} {
		if len(listTestReminders(t, s, other)) != 0 {
			t.Fatalf("cross-owner listing: %+v", other)
		}
		if _, err := s.Cancel(context.Background(), other, r.ID, now); !errors.Is(err, ErrNotFound) {
			t.Fatalf("cross-owner cancellation: %v", err)
		}
	}
	claimed, found, err := s.Claim(context.Background(), now.Add(time.Hour))
	if err != nil || !found || claimed.ID != r.ID || claimed.Text != r.Text || claimed.Owner != owner || claimed.TopicID != 42 {
		t.Fatalf("overdue claim lost destination or content: %+v %v %v", claimed, found, err)
	}
}

func TestCancelClaimRace(t *testing.T) {
	t.Parallel()
	for range 30 {
		s := openTestStore(t, t.TempDir())
		now, owner := time.Now(), (Owner{-100, 17})
		r := createTestReminder(t, s, owner, 42, now)
		var state State
		var claimed bool
		var cancelErr, claimErr error
		var wg sync.WaitGroup
		start := make(chan struct{})
		wg.Go(func() { <-start; state, cancelErr = s.Cancel(context.Background(), owner, r.ID, now) })
		wg.Go(func() { <-start; _, claimed, claimErr = s.Claim(context.Background(), now.Add(time.Hour)) })
		close(start)
		wg.Wait()
		if cancelErr != nil || claimErr != nil || (state == Cancelled && claimed) || (state == Dispatching && !claimed) {
			t.Fatalf("claim/cancel not atomic: state=%s claimed=%v cancel=%v claim=%v", state, claimed, cancelErr, claimErr)
		}
	}
}

func TestTerminalRetention(t *testing.T) {
	t.Parallel()
	s := openTestStore(t, t.TempDir())
	now, owner := time.Now(), (Owner{123, 17})
	for _, state := range []State{Pending, Dispatching, Delivered, Cancelled, Failed} {
		r := createTestReminder(t, s, owner, 0, now)
		execTestSQL(t, s, `UPDATE reminders SET state=?,finished_ms=? WHERE id=?`, state, now.Add(-31*24*time.Hour).UnixMilli(), r.ID)
	}
	for _, age := range []time.Duration{30 * 24 * time.Hour, 29 * 24 * time.Hour} {
		r := createTestReminder(t, s, owner, 0, now)
		execTestSQL(t, s, `UPDATE reminders SET state='failed',finished_ms=? WHERE id=?`, now.Add(-age).UnixMilli(), r.ID)
	}
	if err := s.Prune(context.Background(), now); err != nil {
		t.Fatal(err)
	}
	rows := listTestReminders(t, s, owner)
	if len(rows) != 4 {
		t.Fatalf("retention lost live or recent records, or kept old terminals: %+v", rows)
	}
}

func TestStoreInitializationFailure(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "reminders"), []byte("blocked"), 0o600); err != nil {
		t.Fatal(err)
	}
	if s, err := Open(context.Background(), root); err == nil || s != nil {
		t.Fatalf("initialization failure hidden: %v", err)
	}
}
