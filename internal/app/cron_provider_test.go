//nolint:testpackage // exercises unexported provider wiring
package app

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/allthingscode/gobot/internal/cron"
)

func TestVersionDefaultNonEmpty(t *testing.T) {
	t.Parallel()
	if Version == "" {
		t.Fatal("app.Version must be non-empty so the dashboard home page renders a version")
	}
}

func TestSchedulerCronProviderReadsLiveState(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	wsDir := filepath.Join(root, "workspace")
	if err := os.MkdirAll(wsDir, 0o755); err != nil {
		t.Fatalf("mkdir workspace: %v", err)
	}

	store := cron.Store{Jobs: []cron.Job{
		{
			ID:       "job-1",
			Name:     "Morning Briefing",
			Enabled:  true,
			Schedule: cron.Schedule{Kind: cron.KindCron, Expr: "0 7 * * *"},
			State:    cron.JobState{LastRunAtMS: 1700000000000, NextRunAtMS: 1700086400000, RunCount: 5, SuccessCount: 5},
		},
	}}
	data, err := store.EncodeJSON()
	if err != nil {
		t.Fatalf("encode store: %v", err)
	}
	if err := os.WriteFile(filepath.Join(wsDir, "jobs.json"), data, 0o600); err != nil {
		t.Fatalf("write jobs.json: %v", err)
	}

	provider := NewSchedulerCronProvider(root)
	jobs := provider.Jobs()
	if len(jobs) != 1 {
		t.Fatalf("jobs: got %d, want 1", len(jobs))
	}
	got := jobs[0]
	if got.Name != "Morning Briefing" {
		t.Errorf("name: got %q", got.Name)
	}
	if got.State.LastRunAtMS != 1700000000000 || got.State.NextRunAtMS != 1700086400000 {
		t.Errorf("live state not reflected: %+v", got.State)
	}
}

func TestSchedulerCronProviderMissingStore(t *testing.T) {
	t.Parallel()
	provider := NewSchedulerCronProvider(t.TempDir()) // no jobs.json
	if jobs := provider.Jobs(); jobs != nil {
		t.Fatalf("expected nil jobs when store missing, got %d", len(jobs))
	}
}
