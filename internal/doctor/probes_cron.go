package doctor

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/cron"
)

// checkCron reports cron job health from the persisted job store, read-only.
//
// The data is already collected in cron.JobState (R-014 gap G2: METRICS marked it
// "Collected, not surfaced in doctor"). This probe reads
// {StorageRoot}/workspace/jobs.json without starting a scheduler and renders a
// one-line summary consistent with the C-330 memory line. It is advisory: a job
// with recorded failures surfaces as [WARN] but never blocks startup.
func checkCron(cfg *config.Config) Result {
	path := filepath.Join(cfg.StorageRoot(), "workspace", "jobs.json")

	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return Result{Name: "cron", OK: true, Detail: "no scheduled jobs"}
		}
		return Result{
			Name:        "cron",
			OK:          false,
			Detail:      fmt.Sprintf("cannot read %s: %v", path, err),
			Remediation: "Check permissions on the workspace so gobot doctor can read jobs.json.",
		}
	}

	var store cron.Store
	if err := store.DecodeJSON(data); err != nil {
		return Result{
			Name:        "cron",
			OK:          false,
			Detail:      fmt.Sprintf("cannot parse %s: %v", path, err),
			Remediation: "jobs.json is corrupt; restore from backup or remove it to let gobot recreate the job store.",
		}
	}

	if len(store.Jobs) == 0 {
		return Result{Name: "cron", OK: true, Detail: "no scheduled jobs"}
	}

	var failing []cron.Job
	for _, j := range store.Jobs {
		if j.State.FailureCount > 0 {
			failing = append(failing, j)
		}
	}

	if len(failing) > 0 {
		last := failing[0]
		for _, j := range failing[1:] {
			if j.State.LastRunAtMS > last.State.LastRunAtMS {
				last = j
			}
		}
		return Result{
			Name:        "cron",
			OK:          false,
			Detail:      fmt.Sprintf("%d jobs, %d with failures (last failure on %q)", len(store.Jobs), len(failing), last.Name),
			Remediation: "Check the gobot logs for the failing cron job's error and fix the underlying cause.",
		}
	}

	return Result{
		Name:   "cron",
		OK:     true,
		Detail: fmt.Sprintf("%d jobs, all healthy, next run %s", len(store.Jobs), nextRunSummary(store.Jobs, time.Now().UnixMilli())),
	}
}

// nextRunSummary returns the soonest future next-run relative to nowMS as a
// rounded duration (e.g. "in 4m12s"), or "none scheduled" when no job has a
// future run. It is a pure function so the formatting is deterministically testable.
func nextRunSummary(jobs []cron.Job, nowMS int64) string {
	var soonest int64
	found := false
	for _, j := range jobs {
		if j.State.NextRunAtMS > nowMS && (!found || j.State.NextRunAtMS < soonest) {
			soonest = j.State.NextRunAtMS
			found = true
		}
	}
	if !found {
		return "none scheduled"
	}
	d := time.Duration(soonest-nowMS) * time.Millisecond
	return "in " + d.Round(time.Second).String()
}
