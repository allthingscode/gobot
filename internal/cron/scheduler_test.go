//nolint:testpackage // requires unexported scheduler internals for testing
package cron

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
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
	if alert.Channel != "telegram" { //nolint:goconst // test fixture
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

//nolint:cyclop,funlen // test complexity justified by clock scenario coverage
func TestScheduler_FakeClock(t *testing.T) {
	t.Parallel()
	const eventuallyTimeout = 30 * time.Second

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
	assert.Eventually(t, func() bool {
		return fc.HasWaiter()
	}, eventuallyTimeout, 10*time.Millisecond)

	// 1. Advance to 1000ms. Poll should trigger.
	fc.Advance(1000 * time.Millisecond)

	// Wait for poll to complete and Scheduler to wait on After() again
	assert.Eventually(t, func() bool {
		dispatcher.mu.Lock()
		count := len(dispatcher.payloads)
		dispatcher.mu.Unlock()
		return count == 1 && fc.HasWaiter()
	}, eventuallyTimeout, 10*time.Millisecond)

	dispatcher.mu.Lock()
	if len(dispatcher.payloads) != 1 {
		dispatcher.mu.Unlock()
		t.Errorf("Step 1: want 1 dispatch, got %d", len(dispatcher.payloads))
	} else {
		dispatcher.mu.Unlock()
	}

	// 2. Advance another 1h. Poll should trigger again.
	fc.Advance(1 * time.Hour)
	assert.Eventually(t, func() bool {
		dispatcher.mu.Lock()
		count := len(dispatcher.payloads)
		dispatcher.mu.Unlock()
		return count == 2 && fc.HasWaiter()
	}, eventuallyTimeout, 10*time.Millisecond)

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

//nolint:cyclop // contract test covers reload merge, malformed skip, and freshness marker behavior
func TestSchedulerReloadModularJobsLoadsValidJobsAndPreservesState(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	itemsDir := filepath.Join(tmpDir, "items")
	if err := os.Mkdir(itemsDir, 0o700); err != nil {
		t.Fatal(err)
	}

	writeTestFile(t, filepath.Join(itemsDir, "existing.md"),
		modularJobContent("existing", "Updated Existing", "every(2h)", "updated body"))
	writeTestFile(t, filepath.Join(itemsDir, "new.md"),
		modularJobContent("new", "New Modular", "every(30m)", "new body"))
	writeTestFile(t, filepath.Join(itemsDir, "broken.md"), "---\nid: broken\n---\nmissing schedule")

	mtime := time.Date(2026, 7, 20, 1, 30, 0, 0, time.UTC)
	for _, name := range []string{"existing.md", "new.md", "broken.md"} {
		path := filepath.Join(itemsDir, name)
		if err := os.Chtimes(path, mtime, mtime); err != nil {
			t.Fatal(err)
		}
	}

	oneHour := int64(time.Hour / time.Millisecond)
	existingState := JobState{
		LastRunAtMS: 100,
		NextRunAtMS: 200,
		RunCount:    3,
	}
	s := NewScheduler(filepath.Join(tmpDir, "jobs.json"), itemsDir, nil)
	s.store = &Store{Jobs: []Job{
		{
			ID:       "existing",
			Name:     "Original Existing",
			Enabled:  true,
			Schedule: Schedule{Kind: KindEvery, EveryMS: &oneHour},
			Payload:  Payload{Channel: "telegram", Message: "old body"},
			State:    existingState,
		},
	}}

	s.reloadModularJobs()

	firstReloadMtime := s.lastModularMtime
	if firstReloadMtime <= 0 {
		t.Fatalf("lastModularMtime = %d, want positive value after successful reload", firstReloadMtime)
	}
	jobs := jobsByID(s.Jobs())
	if len(jobs) != 2 {
		t.Fatalf("scheduler jobs = %+v, want 2 valid modular jobs", s.Jobs())
	}
	existing := jobs["existing"]
	if existing.Name != "Updated Existing" {
		t.Errorf("existing name = %q, want updated modular name", existing.Name)
	}
	if existing.Payload.Message != "updated body" {
		t.Errorf("existing message = %q, want updated modular payload", existing.Payload.Message)
	}
	if existing.Schedule.EveryMS == nil || *existing.Schedule.EveryMS != int64(2*time.Hour/time.Millisecond) {
		t.Errorf("existing EveryMS = %v, want 7200000", existing.Schedule.EveryMS)
	}
	if existing.State != existingState {
		t.Errorf("existing state = %+v, want preserved %+v", existing.State, existingState)
	}
	if _, ok := jobs["new"]; !ok {
		t.Fatalf("scheduler missing new modular job in %+v", s.Jobs())
	}
	if _, ok := jobs["broken"]; ok {
		t.Fatalf("scheduler loaded malformed modular job: %+v", jobs["broken"])
	}

	s.reloadModularJobs()
	if s.lastModularMtime != firstReloadMtime {
		t.Errorf("lastModularMtime changed without detected modular change: got %d, want %d", s.lastModularMtime, firstReloadMtime)
	}

	s.itemsDir = filepath.Join(tmpDir, "missing")
	s.reloadModularJobs()
	if s.lastModularMtime != firstReloadMtime {
		t.Errorf("lastModularMtime changed after unsuccessful modular reload: got %d, want %d", s.lastModularMtime, firstReloadMtime)
	}
}

func jobsByID(jobs []Job) map[string]Job {
	byID := make(map[string]Job, len(jobs))
	for _, job := range jobs {
		byID[job.ID] = job
	}
	return byID
}

func TestSchedulerModularEnabledRefresh(t *testing.T) {
	t.Parallel()
	for _, schedule := range []struct {
		name, definition string
		nextDelay        time.Duration
	}{
		{"every", "every(2h)", 2 * time.Hour},
		{"cron", "cron(0 10 * * *, UTC)", time.Hour},
	} {
		for _, enabled := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/enabled=%t", schedule.name, enabled), func(t *testing.T) {
				t.Parallel()
				testSchedulerEnabledRefresh(t, schedule.definition, schedule.nextDelay, enabled)
			})
		}
	}
}

func testSchedulerEnabledRefresh(t *testing.T, definition string, nextDelay time.Duration, enabled bool) {
	t.Helper()
	now := time.Date(2026, 1, 5, 9, 0, 0, 0, time.UTC)
	prior := JobState{LastRunAtMS: now.Add(-time.Hour).UnixMilli(),
		NextRunAtMS: now.Add(-time.Minute).UnixMilli(), RunCount: 9, SuccessCount: 6, FailureCount: 3}
	root := t.TempDir()
	storePath := filepath.Join(root, "jobs.json")
	initial := Store{Jobs: []Job{{ID: "refresh", Name: "Original", Enabled: !enabled,
		Schedule: Schedule{Kind: KindEvery, EveryMS: ptr(int64(1000))},
		Payload:  Payload{Channel: "telegram", Message: "original"}, State: prior}}}
	data, err := initial.EncodeJSON()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(storePath, data, 0o600); err != nil {
		t.Fatal(err)
	}
	itemsDir := filepath.Join(root, "items")
	if err := os.Mkdir(itemsDir, 0o700); err != nil {
		t.Fatal(err)
	}
	definitionPath := filepath.Join(itemsDir, "refresh.md")
	writeEnabledRefreshDefinition(t, definitionPath, definition, !enabled, now.Add(-time.Hour))
	dispatcher := &mockDispatcher{}
	s := NewScheduler(storePath, itemsDir, dispatcher).WithClock(NewFakeClock(now))
	s.reloadModularJobs()
	assertEnabledRefreshJob(t, s.Jobs(), !enabled, prior)
	firstMtime := s.lastModularMtime

	writeEnabledRefreshDefinition(t, definitionPath, definition, enabled, now)
	s.reloadModularJobs()
	assert.NotEqual(t, firstMtime, s.lastModularMtime, "edited definition must actually reload")
	assertEnabledRefreshJob(t, s.Jobs(), enabled, prior)
	// A flag-only reload does not save: check disk before invoking the explicit save path.
	assertEnabledRefreshJob(t, readEnabledRefreshStore(t, storePath).Jobs, !enabled, prior)
	if !enabled {
		if err := s.poll(context.Background()); err != nil {
			t.Fatal(err)
		}
		assert.Empty(t, dispatcher.payloads)
		assertEnabledRefreshJob(t, s.Jobs(), false, prior)
	}
	s.saveStore()
	assertEnabledRefreshJob(t, readEnabledRefreshStore(t, storePath).Jobs, enabled, prior)

	// Inspect constructor-loaded JSON before a modular refresh could mask a bad save.
	// Give the restart its own copy so the original poll cannot overwrite its due state.
	restartPath := filepath.Join(root, "restart.json")
	savedData, err := os.ReadFile(storePath)
	if err != nil {
		t.Fatal(err)
	}
	// Both paths are fixed filenames under t.TempDir; savedData is fixture JSON, not a path.
	if err := os.WriteFile(restartPath, savedData, 0o600); err != nil { //nolint:gosec // G703: isolated temporary fixture copy
		t.Fatal(err)
	}
	restartedDispatcher := &mockDispatcher{}
	restarted := NewScheduler(restartPath, itemsDir, restartedDispatcher).WithClock(NewFakeClock(now))
	assertEnabledRefreshJob(t, restarted.Jobs(), enabled, prior)
	assertEnabledRefreshPolling(t, s, restarted, dispatcher, restartedDispatcher, enabled, prior, now, nextDelay)
}

func assertEnabledRefreshPolling(t *testing.T, s, restarted *Scheduler, dispatcher, restartedDispatcher *mockDispatcher, enabled bool, prior JobState, now time.Time, nextDelay time.Duration) {
	t.Helper()
	for _, scheduler := range []*Scheduler{s, restarted} {
		if err := scheduler.poll(context.Background()); err != nil {
			t.Fatal(err)
		}
		want := prior
		if enabled {
			want.LastRunAtMS = now.UnixMilli()
			want.NextRunAtMS = now.Add(nextDelay).UnixMilli()
			want.RunCount++
			want.SuccessCount++
		}
		assertEnabledRefreshJob(t, scheduler.Jobs(), enabled, want)
		if err := scheduler.poll(context.Background()); err != nil {
			t.Fatal(err)
		}
		assertEnabledRefreshJob(t, scheduler.Jobs(), enabled, want)
	}
	wantDispatches := 0
	if enabled {
		wantDispatches = 1
	}
	assert.Len(t, dispatcher.payloads, wantDispatches)
	assert.Len(t, restartedDispatcher.payloads, wantDispatches)
	assert.Empty(t, dispatcher.alerts)
	assert.Empty(t, restartedDispatcher.alerts)
}

func writeEnabledRefreshDefinition(t *testing.T, path, schedule string, enabled bool, mtime time.Time) {
	t.Helper()
	content := fmt.Sprintf("---\nid: refresh\nname: Refreshed\nschedule: %s\nenabled: %t\nchannel: telegram\n---\nrefreshed body\n", schedule, enabled)
	writeTestFile(t, path, content)
	if err := os.Chtimes(path, mtime, mtime); err != nil {
		t.Fatal(err)
	}
}

func readEnabledRefreshStore(t *testing.T, path string) Store {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var store Store
	if err := store.DecodeJSON(data); err != nil {
		t.Fatal(err)
	}
	return store
}

func assertEnabledRefreshJob(t *testing.T, jobs []Job, enabled bool, state JobState) {
	t.Helper()
	if len(jobs) != 1 {
		t.Fatalf("jobs = %+v, want exactly one retained job", jobs)
	}
	assert.Equal(t, "refresh", jobs[0].ID)
	assert.Equal(t, enabled, jobs[0].Enabled)
	assert.Equal(t, state, jobs[0].State)
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
		return fmt.Errorf("context canceled: %w", ctx.Err())
	}
}

func (m *blockingDispatcher) Alert(_ context.Context, p Payload) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.alerts = append(m.alerts, p)
	return nil
}

// TestSchedulerSendFailureAlert_AlreadyNotified verifies that when the
// dispatcher returns an AlreadyNotifiedError, sendFailureAlert skips Alert()
// (the dispatcher self-notified), and otherwise Alert() fires as usual.
func TestSchedulerSendFailureAlert_AlreadyNotified(t *testing.T) {
	t.Parallel()

	plainErr := errors.New("boom")
	wrappedErr := &AlreadyNotifiedError{Err: fmt.Errorf("dispatch email: %w", plainErr)}

	tests := []struct {
		name       string
		err        error
		wantAlerts int
	}{
		{
			name:       "plain error triggers Alert",
			err:        plainErr,
			wantAlerts: 1,
		},
		{
			name:       "AlreadyNotifiedError suppresses Alert",
			err:        wrappedErr,
			wantAlerts: 0,
		},
		{
			name:       "wrapped AlreadyNotifiedError still suppresses Alert",
			err:        fmt.Errorf("outer: %w", wrappedErr),
			wantAlerts: 0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			dispatcher := &mockDispatcher{}
			s := NewScheduler("", "", dispatcher)
			dj := dueJob{
				index:   0,
				id:      "job-1",
				name:    "Test Job",
				payload: Payload{Channel: "telegram", To: "telegram:1"},
			}
			s.sendFailureAlert(context.Background(), dj, tt.err)
			assert.Equal(t, tt.wantAlerts, len(dispatcher.alerts), "alert count mismatch")
		})
	}
}

// TestAlreadyNotifiedError_ErrorAndUnwrap exercises the error-interface
// methods on the sentinel type.
func TestAlreadyNotifiedError_ErrorAndUnwrap(t *testing.T) {
	t.Parallel()

	inner := errors.New("inner failure")
	e := &AlreadyNotifiedError{Err: inner}
	assert.Equal(t, "inner failure", e.Error())
	assert.Equal(t, inner, errors.Unwrap(e))

	// Zero-value AlreadyNotifiedError must not panic.
	empty := &AlreadyNotifiedError{}
	assert.Equal(t, "already notified", empty.Error())
	assert.Nil(t, errors.Unwrap(empty))

	// errors.As must succeed against the sentinel through wrapping.
	wrapped := fmt.Errorf("ctx: %w", e)
	var target *AlreadyNotifiedError
	assert.True(t, errors.As(wrapped, &target))
	assert.Same(t, e, target)
}
