package cron

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

type mockDispatcher struct {
	called bool
	payload Payload
}

func (m *mockDispatcher) Dispatch(ctx context.Context, p Payload) error {
	m.called = true
	m.payload = p
	return nil
}

func TestComputeNextRun(t *testing.T) {
	atTime := int64(2000)
	everyInterval := int64(1000)

	tests := []struct {
		name     string
		schedule Schedule
		nowMS    int64
		want     int64
	}{
		{
			name: "kind at - in future",
			schedule: Schedule{Kind: KindAt, AtMS: &atTime},
			nowMS: 1000,
			want: 2000,
		},
		{
			name: "kind at - in past",
			schedule: Schedule{Kind: KindAt, AtMS: &atTime},
			nowMS: 3000,
			want: 0,
		},
		{
			name: "kind every",
			schedule: Schedule{Kind: KindEvery, EveryMS: &everyInterval},
			nowMS: 5000,
			want: 6000,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := ComputeNextRun(tt.schedule, tt.nowMS); got != tt.want {
				t.Errorf("ComputeNextRun() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestComputeNextRunKindCron(t *testing.T) {
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
	tmpDir := t.TempDir()
	storePath := filepath.Join(tmpDir, "jobs.json")

	// 1. Create initial jobs.json
	atTime := int64(1000) // will be due if now >= 1000
	initialStore := Store{
		Jobs: []Job{
			{
				ID:      "job1",
				Name:    "Test Job",
				Enabled: true,
				Schedule: Schedule{Kind: KindAt, AtMS: &atTime},
				Payload: Payload{Channel: "telegram", Message: "test"},
				State: JobState{NextRunAtMS: 500}, // Already due
			},
		},
	}
	data, _ := initialStore.EncodeJSON()
	_ = os.WriteFile(storePath, data, 0644)

	dispatcher := &mockDispatcher{}
	s := NewScheduler(storePath, "", dispatcher)

	// 2. Poll
	ctx := context.Background()
	if err := s.poll(ctx); err != nil {
		t.Fatalf("poll failed: %v", err)
	}

	// 3. Verify dispatch was called
	if !dispatcher.called {
		t.Errorf("expected dispatcher to be called")
	}

	// 4. Verify store was reloaded and updated
	if s.store == nil {
		t.Fatal("store should not be nil after poll")
	}
	if s.store.Jobs[0].State.RunCount != 1 {
		t.Errorf("expected RunCount to be 1, got %d", s.store.Jobs[0].State.RunCount)
	}

	// 5. Verify next run was calculated (atTime is 1000, so it's not in future if now > 1000)
	// Our test runs now, which is > 1000, so ComputeNextRun(KindAt, 1000) should be 0.
}
