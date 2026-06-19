//nolint:testpackage // requires unexported clock/scheduler internals for testing
package cron

import (
	"context"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

const anchorJobID = "anchor_job"

// clockAdvanceDispatcher simulates a job whose execution takes longer than its
// schedule interval by advancing the injected fake clock while it "runs".
type clockAdvanceDispatcher struct {
	mu       sync.Mutex
	clock    *fakeClock
	advance  time.Duration
	payloads []Payload
}

func (d *clockAdvanceDispatcher) Dispatch(_ context.Context, p Payload) error {
	d.clock.Advance(d.advance)
	d.mu.Lock()
	d.payloads = append(d.payloads, p)
	d.mu.Unlock()
	return nil
}

func (d *clockAdvanceDispatcher) count() int {
	d.mu.Lock()
	defer d.mu.Unlock()
	return len(d.payloads)
}

// assertNoRefire polls again without advancing the clock and asserts the job
// did not dispatch a second time (the back-to-back re-fire regression).
func assertNoRefire(t *testing.T, s *Scheduler, disp *clockAdvanceDispatcher) {
	t.Helper()
	if err := s.poll(context.Background()); err != nil {
		t.Fatalf("follow-up poll: %v", err)
	}
	if c := disp.count(); c != 1 {
		t.Errorf("expected no back-to-back re-fire (1 dispatch), got %d", c)
	}
}

// B-006: an Every job that runs longer than its interval must have its next run
// anchored to the dispatch-completion time, not the poll-start time. Otherwise
// it is scheduled in the past and re-fires back-to-back on the next poll.
func TestPoll_EveryJob_NextRunAnchoredToCompletion(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	storePath := filepath.Join(dir, "jobs.json")
	const intervalMS = int64(100)

	if _, err := SeedJob(storePath, EveryJob(anchorJobID, "Anchor Job", "[SYSTEM] ANCHOR", intervalMS)); err != nil {
		t.Fatalf("seed: %v", err)
	}

	fc := NewFakeClock(time.UnixMilli(1000))
	// Dispatch advances the clock far past the interval (slow job).
	disp := &clockAdvanceDispatcher{clock: fc, advance: time.Duration(intervalMS*5) * time.Millisecond}
	s := NewScheduler(storePath, "", disp).WithClock(fc)
	ctx := context.Background()

	// Init poll schedules the first run (not due yet).
	if err := s.poll(ctx); err != nil {
		t.Fatalf("init poll: %v", err)
	}
	// Make the job due, then poll: it dispatches and the slow dispatch pushes
	// the clock well past the original poll-start time.
	fc.Advance(time.Duration(intervalMS+1) * time.Millisecond)
	if err := s.poll(ctx); err != nil {
		t.Fatalf("dispatch poll: %v", err)
	}

	completionMS := fc.Now().UnixMilli()
	store := assertDecodableStore(t, storePath)
	if len(store.Jobs) != 1 {
		t.Fatalf("expected 1 job, got %d", len(store.Jobs))
	}
	got := store.Jobs[0].State

	if got.SuccessCount != 1 {
		t.Fatalf("expected SuccessCount 1 after one dispatch, got %d", got.SuccessCount)
	}
	// AC1/AC2: next run is anchored to completion, strictly in the future.
	if got.NextRunAtMS <= completionMS {
		t.Errorf("NextRunAtMS %d not after completion %d (scheduled in the past)", got.NextRunAtMS, completionMS)
	}
	if got.NextRunAtMS != completionMS+intervalMS {
		t.Errorf("expected NextRunAtMS == completion+interval (%d), got %d", completionMS+intervalMS, got.NextRunAtMS)
	}

	// Regression: a follow-up poll WITHOUT advancing the clock must not re-fire.
	assertNoRefire(t, s, disp)
}

// B-006: the same anchor fix must hold for cron schedules - a cron slot that
// elapses during a long dispatch must not be scheduled in the past.
func TestPoll_CronJob_NextRunAnchoredToCompletion(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	storePath := filepath.Join(dir, "jobs.json")

	cronJob := Job{
		ID:      anchorJobID,
		Name:    "Anchor Cron",
		Enabled: true,
		Schedule: Schedule{
			Kind: KindCron,
			Expr: "* * * * *", // every minute (60s slots)
			TZ:   "UTC",
		},
		Payload: Payload{ID: anchorJobID, Message: "[SYSTEM] ANCHOR_CRON"},
	}
	if _, err := SeedJob(storePath, cronJob); err != nil {
		t.Fatalf("seed: %v", err)
	}

	// Start at epoch (00:00:00). First slot is 00:01:00 = 60_000ms.
	fc := NewFakeClock(time.UnixMilli(0))
	// Slow dispatch crosses two minute boundaries.
	disp := &clockAdvanceDispatcher{clock: fc, advance: 120_000 * time.Millisecond}
	s := NewScheduler(storePath, "", disp).WithClock(fc)
	ctx := context.Background()

	if err := s.poll(ctx); err != nil {
		t.Fatalf("init poll: %v", err)
	}
	// Advance just past the first slot so the job is due, then dispatch.
	fc.Advance(60_001 * time.Millisecond)
	if err := s.poll(ctx); err != nil {
		t.Fatalf("dispatch poll: %v", err)
	}

	completionMS := fc.Now().UnixMilli()
	store := assertDecodableStore(t, storePath)
	next := store.Jobs[0].State.NextRunAtMS
	// AC3: next cron slot is strictly after dispatch completion, not a past slot.
	if next <= completionMS {
		t.Errorf("cron NextRunAtMS %d not after completion %d (past slot)", next, completionMS)
	}
	if want := ComputeNextRun(cronJob.Schedule, completionMS); next != want {
		t.Errorf("expected cron next slot from completion (%d), got %d", want, next)
	}

	assertNoRefire(t, s, disp)
}
