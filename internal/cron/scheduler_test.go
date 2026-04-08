package cron

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

type mockDispatcher struct {
	mu        sync.Mutex
	payloads  []Payload
	alerts    []Payload
	failFirst bool
	failErr   error
}

func (m *mockDispatcher) Dispatch(_ context.Context, p Payload) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.payloads = append(m.payloads, p)
	if m.failFirst && len(m.payloads) == 1 {
		return m.failErr
	}
	return nil
}

func (m *mockDispatcher) Alert(_ context.Context, p Payload) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.alerts = append(m.alerts, p)
	return nil
}

func TestComputeNextRun(t *testing.T) {
	t.Parallel()
	atTime := int64(2000)
	everyInterval := int64(1000)

	tests := []struct {
		name     string
		schedule Schedule
		nowMS    int64
		want     int64
	}{
		{
			name:     "kind at - in future",
			schedule: Schedule{Kind: KindAt, AtMS: &atTime},
			nowMS:    1000,
			want:     2000,
		},
		{
			name:     "kind at - in past",
			schedule: Schedule{Kind: KindAt, AtMS: &atTime},
			nowMS:    3000,
			want:     0,
		},
		{
			name:     "kind every",
			schedule: Schedule{Kind: KindEvery, EveryMS: &everyInterval},
			nowMS:    5000,
			want:     6000,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			if got := ComputeNextRun(tt.schedule, tt.nowMS); got != tt.want {
				t.Errorf("ComputeNextRun() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestComputeNextRunKindCron(t *testing.T) {
	t.Parallel()
	// Monday 2026-01-05 00:00:00 UTC
	monday := time.Date(2026, 1, 5, 0, 0, 0, 0, time.UTC)
	mondayMS := monday.UnixMilli()

	// Saturday 2026-01-10 09:01:00 UTC
	saturdayAfter9 := time.Date(2026, 1, 10, 9, 1, 0, 0, time.UTC)
	saturdayAfter9MS := saturdayAfter9.UnixMilli()

	tests := []struct {
		name     string
		schedule Schedule
		nowMS    int64
		wantMS   int64
	}{
		{
			name:     "every day at 09:00 UTC",
			schedule: Schedule{Kind: KindCron, Expr: "0 9 * * *"},
			nowMS:    mondayMS,
			// same Monday at 09:00 UTC
			wantMS: time.Date(2026, 1, 5, 9, 0, 0, 0, time.UTC).UnixMilli(),
		},
		{
			name:     "weekdays only 09:00 - now is Saturday after 9",
			schedule: Schedule{Kind: KindCron, Expr: "0 9 * * 1-5"},
			nowMS:    saturdayAfter9MS,
			// next Monday 09:00 UTC
			wantMS: time.Date(2026, 1, 12, 9, 0, 0, 0, time.UTC).UnixMilli(),
		},
		{
			name:     "invalid expression returns 0",
			schedule: Schedule{Kind: KindCron, Expr: "not-a-cron"},
			nowMS:    mondayMS,
			wantMS:   0,
		},
		{
			name:     "empty expr returns 0",
			schedule: Schedule{Kind: KindCron, Expr: ""},
			nowMS:    mondayMS,
			wantMS:   0,
		},
		{
			name: "with valid timezone America/New_York in January (EST = UTC-5)",
			// 09:00 EST = 14:00 UTC
			schedule: Schedule{Kind: KindCron, Expr: "0 9 * * *", TZ: "America/New_York"},
			nowMS:    mondayMS, // midnight UTC = 19:00 previous evening EST, so 09:00 same day EST is still ahead
			wantMS:   time.Date(2026, 1, 5, 14, 0, 0, 0, time.UTC).UnixMilli(),
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got := ComputeNextRun(tt.schedule, tt.nowMS)
			if got != tt.wantMS {
				t.Errorf("ComputeNextRun() = %v (%s), want %v (%s)",
					got, time.UnixMilli(got).UTC(),
					tt.wantMS, time.UnixMilli(tt.wantMS).UTC())
			}
		})
	}
}

func TestSchedulerPoll(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	storePath := filepath.Join(tmpDir, "jobs.json")

	// 1. Create initial jobs.json
	atTime := int64(1000) // will be due if now >= 1000
	initialStore := Store{
		Jobs: []Job{
			{
				ID:       "job1",
				Name:     "Test Job",
				Enabled:  true,
				Schedule: Schedule{Kind: KindAt, AtMS: &atTime},
				Payload:  Payload{Channel: "telegram", Message: "test"},
				State:    JobState{NextRunAtMS: 500}, // Already due
			},
		},
	}
	data, _ := initialStore.EncodeJSON()
	_ = os.WriteFile(storePath, data, 0o600)

	dispatcher := &mockDispatcher{}
	start := time.UnixMilli(1000)
	fc := NewFakeClock(start)
	s := NewScheduler(storePath, "", dispatcher).WithClock(fc)

	// 2. Poll
	ctx := context.Background()
	if err := s.poll(ctx); err != nil {
		t.Fatalf("poll failed: %v", err)
	}

	// 3. Verify dispatch was called
	if len(dispatcher.payloads) == 0 {
		t.Errorf("expected dispatcher to be called")
	}

	// 4. Verify store was reloaded and updated
	if s.store == nil {
		t.Fatal("store should not be nil after poll")
	}
	if s.store.Jobs[0].State.RunCount != 1 {
		t.Errorf("expected RunCount to be 1, got %d", s.store.Jobs[0].State.RunCount)
	}
}

func TestSchedulerPoll_InitializesNewJob(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	storePath := filepath.Join(tmpDir, "jobs.json")

	// Write store with a job that has NextRunAtMS=0 (first-load zero value).
	initialStore := Store{
		Jobs: []Job{
			{
				ID:       "job1",
				Name:     "Morning Briefing",
				Enabled:  true,
				Schedule: Schedule{Kind: KindCron, Expr: "45 8 * * *"},
				Payload:  Payload{Channel: "telegram", To: "telegram:999", Message: "good morning"},
				State:    JobState{NextRunAtMS: 0},
			},
		},
	}
	data, _ := initialStore.EncodeJSON()
	_ = os.WriteFile(storePath, data, 0o600)

	dispatcher := &mockDispatcher{}
	start := time.Date(2026, 1, 5, 0, 0, 0, 0, time.UTC) // Midnight
	fc := NewFakeClock(start)
	s := NewScheduler(storePath, "", dispatcher).WithClock(fc)

	ctx := context.Background()
	if err := s.poll(ctx); err != nil {
		t.Fatalf("poll failed: %v", err)
	}

	// Job should NOT fire on the initialization poll.
	if len(dispatcher.payloads) != 0 {
		t.Errorf("new job must not fire on initialization poll, got %d dispatches", len(dispatcher.payloads))
	}

	// NextRunAtMS must now be set to a future time (08:45).
	wantMS := time.Date(2026, 1, 5, 8, 45, 0, 0, time.UTC).UnixMilli()
	if s.store.Jobs[0].State.NextRunAtMS != wantMS {
		t.Errorf("NextRunAtMS: want %d, got %d", wantMS, s.store.Jobs[0].State.NextRunAtMS)
	}
}

func TestSchedulerPoll_FailureAlert(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	storePath := filepath.Join(tmpDir, "jobs.json")

	atTime := int64(1000)
	initialStore := Store{
		Jobs: []Job{
			{
				ID:       "job1",
				Name:     "Morning Briefing",
				Enabled:  true,
				Schedule: Schedule{Kind: KindAt, AtMS: &atTime},
				Payload:  Payload{Channel: "telegram", To: "telegram:999", Message: "hello"},
				State:    JobState{NextRunAtMS: 500},
			},
		},
	}
	data, _ := initialStore.EncodeJSON()
	_ = os.WriteFile(storePath, data, 0o600)

	dispatcher := &mockDispatcher{
		failFirst: true,
		failErr:   errors.New("gemini: rate limit"),
	}
	start := time.UnixMilli(1000)
	fc := NewFakeClock(start)
	s := NewScheduler(storePath, "", dispatcher).WithClock(fc)

	ctx := context.Background()
	if err := s.poll(ctx); err != nil {
		t.Fatalf("poll failed: %v", err)
	}

	// Original job dispatch must fail once.
	if len(dispatcher.payloads) != 1 {
		t.Fatalf("want 1 dispatch (job only), got %d", len(dispatcher.payloads))
	}
	// Alert must go through Alert(), not Dispatch().
	if len(dispatcher.alerts) != 1 {
		t.Fatalf("want 1 alert, got %d", len(dispatcher.alerts))
	}
	alert := dispatcher.alerts[0]
	if alert.Channel != "telegram" {
		t.Errorf("alert channel: want telegram, got %q", alert.Channel)
	}
	if alert.To != "telegram:999" {
		t.Errorf("alert to: want telegram:999, got %q", alert.To)
	}
	if !strings.Contains(alert.Message, "Morning Briefing") {
		t.Errorf("alert message should contain job name, got %q", alert.Message)
	}
	if !strings.Contains(alert.Message, "gemini: rate limit") {
		t.Errorf("alert message should contain error text, got %q", alert.Message)
	}
	if s.store.Jobs[0].State.FailureCount != 1 {
		t.Errorf("want FailureCount=1, got %d", s.store.Jobs[0].State.FailureCount)
	}
}

func TestSchedulerPoll_JobTimeout(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	storePath := filepath.Join(tmpDir, "jobs.json")

	atTime := int64(1000)
	initialStore := Store{
		Jobs: []Job{
			{
				ID:       "slow-job",
				Name:     "Slow Job",
				Enabled:  true,
				Schedule: Schedule{Kind: KindAt, AtMS: &atTime},
				Payload:  Payload{Channel: "telegram", Message: "slow"},
				State:    JobState{NextRunAtMS: 500},
			},
		},
	}
	data, _ := initialStore.EncodeJSON()
	_ = os.WriteFile(storePath, data, 0o600)

	// Dispatcher that blocks
	dispatcher := &blockingDispatcher{delay: 50 * time.Millisecond}
	start := time.UnixMilli(1000)
	fc := NewFakeClock(start)
	s := NewScheduler(storePath, "", dispatcher).WithClock(fc).WithJobTimeout(1 * time.Millisecond)

	ctx := context.Background()
	if err := s.poll(ctx); err != nil {
		t.Fatalf("poll failed: %v", err)
	}

	if len(dispatcher.payloads) != 1 {
		t.Fatalf("want 1 dispatch, got %d", len(dispatcher.payloads))
	}

	err := dispatcher.lastErr
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("expected context.DeadlineExceeded, got %v", err)
	}

	if s.store.Jobs[0].State.FailureCount != 1 {
		t.Errorf("want FailureCount=1, got %d", s.store.Jobs[0].State.FailureCount)
	}
}

func TestScheduler_FakeClock(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	storePath := filepath.Join(tmpDir, "jobs.json")

	// Job triggers every 1 hour
	every1h := int64(3600000)
	initialStore := Store{
		Jobs: []Job{
			{
				ID:       "job1",
				Name:     "Hourly Job",
				Enabled:  true,
				Schedule: Schedule{Kind: KindEvery, EveryMS: &every1h},
				Payload:  Payload{Channel: "telegram", Message: "tick"},
				State:    JobState{NextRunAtMS: 1000},
			},
		},
	}
	data, _ := initialStore.EncodeJSON()
	_ = os.WriteFile(storePath, data, 0o600)

	dispatcher := &mockDispatcher{}
	start := time.UnixMilli(0)
	fc := NewFakeClock(start)
	s := NewScheduler(storePath, "", dispatcher).WithClock(fc)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Run scheduler in background
	errCh := make(chan error, 1)
	go func() {
		errCh <- s.Run(ctx)
	}()

	// Wait for scheduler to reach After()
	for i := 0; i < 50; i++ {
		if fc.HasWaiter() {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	// 1. Advance to 1000ms. Poll should trigger.
	fc.Advance(1000 * time.Millisecond)

	// Wait for poll to complete and Scheduler to wait on After() again
	for i := 0; i < 100; i++ {
		dispatcher.mu.Lock()
		count := len(dispatcher.payloads)
		dispatcher.mu.Unlock()
		if count == 1 && fc.HasWaiter() {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	dispatcher.mu.Lock()
	if len(dispatcher.payloads) != 1 {
		dispatcher.mu.Unlock()
		t.Errorf("Step 1: want 1 dispatch, got %d", len(dispatcher.payloads))
	} else {
		dispatcher.mu.Unlock()
	}

	// 2. Advance another 1h. Poll should trigger again.
	fc.Advance(1 * time.Hour)
	for i := 0; i < 100; i++ {
		dispatcher.mu.Lock()
		count := len(dispatcher.payloads)
		dispatcher.mu.Unlock()
		if count == 2 && fc.HasWaiter() {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	dispatcher.mu.Lock()
	if len(dispatcher.payloads) != 2 {
		dispatcher.mu.Unlock()
		t.Errorf("Step 2: want 2 dispatches, got %d", len(dispatcher.payloads))
	} else {
		dispatcher.mu.Unlock()
	}

	cancel()
	<-errCh
}

func TestSchedulerReloadObservability(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	storePath := filepath.Join(tmpDir, "jobs.json")

	// 1. Valid initial store
	initialStore := Store{Jobs: []Job{}}
	data, _ := initialStore.EncodeJSON()
	_ = os.WriteFile(storePath, data, 0o600)

	dispatcher := &mockDispatcher{}
	start := time.UnixMilli(0)
	fc := NewFakeClock(start)
	s := NewScheduler(storePath, "", dispatcher).WithClock(fc)

	ctx := context.Background()
	_ = s.poll(ctx)
	if s.lastReloadErr != nil {
		t.Fatalf("expected no reload error, got %v", s.lastReloadErr)
	}

	// 2. Break store
	_ = os.WriteFile(storePath, []byte("invalid json"), 0o600)
	// Update file time to trigger reload - Must be different from initial load
	// Initial load in NewScheduler sets lastMtime
	info, _ := os.Stat(storePath)
	s.lastMtime = info.ModTime().UnixNano()
	s.lastSize = info.Size()

	// Now modify it again to trigger ShouldReload
	_ = os.WriteFile(storePath, []byte("even more invalid json"), 0o600)
	mtime := info.ModTime().Add(1 * time.Second)
	_ = os.Chtimes(storePath, mtime, mtime)

	_ = s.poll(ctx)
	if s.lastReloadErr == nil {
		t.Fatal("expected reload error, got nil")
	}
	firstErrAt := s.lastReloadErrAt

	// 3. Poll again immediately (no repeat warning yet)
	fc.Advance(1 * time.Minute)
	_ = s.poll(ctx)
	if !s.lastReloadErrAt.Equal(firstErrAt) {
		t.Errorf("lastReloadErrAt change too early: got %v, want %v", s.lastReloadErrAt, firstErrAt)
	}

	// 4. Advance 5 minutes - should trigger repeat and update timestamp
	fc.Advance(5 * time.Minute)
	_ = s.poll(ctx)
	if s.lastReloadErrAt.Equal(firstErrAt) {
		t.Error("expected lastReloadErrAt to be updated after 5m warning")
	}

	// 5. Fix store
	_ = os.WriteFile(storePath, data, 0o600)
	mtime = s.clock.Now().Add(1 * time.Second)
	_ = os.Chtimes(storePath, mtime, mtime)

	_ = s.poll(ctx)
	if s.lastReloadErr != nil {
		t.Errorf("expected reload error to be cleared, got %v", s.lastReloadErr)
	}
}

type blockingDispatcher struct {
	mu       sync.Mutex
	delay    time.Duration
	payloads []Payload
	alerts   []Payload
	lastErr  error
}

func (m *blockingDispatcher) Dispatch(ctx context.Context, p Payload) error {
	m.mu.Lock()
	m.payloads = append(m.payloads, p)
	m.mu.Unlock()
	select {
	case <-time.After(m.delay):
		return nil
	case <-ctx.Done():
		m.mu.Lock()
		m.lastErr = ctx.Err()
		m.mu.Unlock()
		return ctx.Err()
	}
}

func (m *blockingDispatcher) Alert(_ context.Context, p Payload) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.alerts = append(m.alerts, p)
	return nil
}
