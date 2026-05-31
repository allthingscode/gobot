package app

import (
	"path/filepath"

	"github.com/allthingscode/gobot/internal/cron"
)

// SchedulerCronProvider adapts the cron scheduler's persisted job store to the
// dash.CronProvider interface so the dashboard can render live job state
// (last run, next run, status) instead of static configured tasks.
//
// The running CronDispatcher persists job state back to jobs.json on every
// poll (see scheduler.saveStore), so reading the store on demand reflects the
// live scheduler state without sharing a scheduler instance across goroutines.
type SchedulerCronProvider struct {
	storePath string
	itemsDir  string
}

// NewSchedulerCronProvider builds a CronProvider rooted at the same workspace
// paths the CronDispatcher uses for its scheduler.
func NewSchedulerCronProvider(storageRoot string) *SchedulerCronProvider {
	return &SchedulerCronProvider{
		storePath: filepath.Join(storageRoot, "workspace", "jobs.json"),
		itemsDir:  filepath.Join(storageRoot, "workspace", "jobs"),
	}
}

// Jobs returns the current set of scheduled jobs with their live state.
// It constructs a fresh read-only scheduler that loads jobs.json at
// construction; no polling loop is started.
func (p *SchedulerCronProvider) Jobs() []cron.Job {
	if p == nil {
		return nil
	}
	scheduler := cron.NewScheduler(p.storePath, p.itemsDir, nil)
	return scheduler.Jobs()
}
