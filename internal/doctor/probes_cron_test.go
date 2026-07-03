//nolint:testpackage // exercises unexported checkCron and nextRunSummary
package doctor

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/cron"
)

// writeJobsJSON writes a jobs.json fixture under {root}/workspace.
func writeJobsJSON(t *testing.T, root string, jobs []cron.Job) {
	t.Helper()
	ws := filepath.Join(root, "workspace")
	if err := os.MkdirAll(ws, 0o755); err != nil {
		t.Fatal(err)
	}
	store := cron.Store{Jobs: jobs}
	data, err := store.EncodeJSON()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(ws, "jobs.json"), data, 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestNextRunSummary(t *testing.T) {
	t.Parallel()
	const now = int64(1_000_000)
	cases := []struct {
		name string
		jobs []cron.Job
		want string
	}{
		{
			name: "soonest future wins",
			jobs: []cron.Job{
				{State: cron.JobState{NextRunAtMS: now + 90_000}},
				{State: cron.JobState{NextRunAtMS: now + 5_000}},
				{State: cron.JobState{NextRunAtMS: now - 1_000}},
			},
			want: "in 5s",
		},
		{
			name: "no future run",
			jobs: []cron.Job{{State: cron.JobState{NextRunAtMS: now - 1_000}}},
			want: "none scheduled",
		},
		{
			name: "minutes rounding",
			jobs: []cron.Job{{State: cron.JobState{NextRunAtMS: now + 252_000}}},
			want: "in 4m12s",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			if got := nextRunSummary(tc.jobs, now); got != tc.want {
				t.Errorf("nextRunSummary = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestCheckCron_MissingFile(t *testing.T) {
	t.Parallel()
	r := checkCron(cfgWithRoot(t.TempDir()))
	if !r.OK || r.Critical {
		t.Errorf("missing jobs.json = {OK:%v Critical:%v}, want healthy", r.OK, r.Critical)
	}
	if r.Detail != "no scheduled jobs" {
		t.Errorf("Detail = %q, want %q", r.Detail, "no scheduled jobs")
	}
}

func TestCheckCron_ZeroJobs(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	writeJobsJSON(t, root, nil)
	r := checkCron(cfgWithRoot(root))
	if !r.OK {
		t.Errorf("zero jobs should be OK, got %+v", r)
	}
	if r.Detail != "no scheduled jobs" {
		t.Errorf("Detail = %q, want %q", r.Detail, "no scheduled jobs")
	}
}

func TestCheckCron_HealthyJobs(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	// Far-future next run so the line is OK; exact duration is covered by
	// TestNextRunSummary, so here we only assert the OK shape and prefix.
	writeJobsJSON(t, root, []cron.Job{
		{Name: "a", State: cron.JobState{NextRunAtMS: 9_000_000_000_000}},
		{Name: "b", State: cron.JobState{NextRunAtMS: 9_000_000_001_000}},
	})
	r := checkCron(cfgWithRoot(root))
	if !r.OK || r.Critical {
		t.Fatalf("healthy jobs = {OK:%v Critical:%v}, want healthy", r.OK, r.Critical)
	}
	if !strings.HasPrefix(r.Detail, "2 jobs, all healthy, next run in ") {
		t.Errorf("Detail = %q, want prefix %q", r.Detail, "2 jobs, all healthy, next run in ")
	}
}

func TestCheckCron_FailingJobWarns(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	writeJobsJSON(t, root, []cron.Job{
		{Name: "healthy", State: cron.JobState{NextRunAtMS: 9_000_000_000_000}},
		{Name: "older-fail", State: cron.JobState{FailureCount: 1, LastRunAtMS: 100}},
		{Name: "recent-fail", State: cron.JobState{FailureCount: 3, LastRunAtMS: 200}},
	})

	r := checkCron(cfgWithRoot(root))
	if r.OK {
		t.Error("a job with FailureCount > 0 must be advisory WARN (OK=false)")
	}
	if r.Critical {
		t.Error("cron WARN must remain non-critical (must not block startup)")
	}
	want := `3 jobs, 2 with failures (last failure on "recent-fail")`
	if r.Detail != want {
		t.Errorf("Detail = %q, want %q", r.Detail, want)
	}
	if r.Remediation == "" {
		t.Error("failing cron line must carry a remediation")
	}
}

func TestCheckCron_CorruptFile(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	ws := filepath.Join(root, "workspace")
	if err := os.MkdirAll(ws, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(ws, "jobs.json"), []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}

	r := checkCron(cfgWithRoot(root))
	if r.OK {
		t.Error("corrupt jobs.json must be advisory WARN (OK=false)")
	}
	if r.Critical {
		t.Error("corrupt jobs.json must remain non-critical")
	}
	if r.Remediation == "" {
		t.Error("corrupt jobs.json must carry a remediation")
	}
}

func TestGetResults_IncludesCron(t *testing.T) {
	t.Parallel()
	results := GetResults(doctorTestCfg(t), nil)
	for i := range results {
		if results[i].Name == "cron" {
			if results[i].Critical {
				t.Error("cron result must be non-critical")
			}
			return
		}
	}
	t.Fatal("GetResults did not include a 'cron' result")
}
