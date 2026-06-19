package cron

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"sync"
	"time"

	"github.com/allthingscode/gobot/internal/logattr"
	"github.com/allthingscode/gobot/internal/state"
	robfigcron "github.com/robfig/cron/v3"
)

// AlreadyNotifiedError signals that the dispatcher has already delivered a
// failure notification for this job (e.g. dispatchEmail sent its own failure
// email). When the scheduler observes this error type, sendFailureAlert
// suppresses the generic Alerter call to prevent duplicate notifications.
type AlreadyNotifiedError struct {
	Err error
}

// Error returns the underlying error message.
func (e *AlreadyNotifiedError) Error() string {
	if e.Err == nil {
		return "already notified"
	}
	return e.Err.Error()
}

// Unwrap returns the wrapped error for errors.As/Is compatibility.
func (e *AlreadyNotifiedError) Unwrap() error { return e.Err }

// Dispatcher defines the interface for sending job messages.
type Dispatcher interface {
	Dispatch(ctx context.Context, p Payload) error
}

// Alerter is an optional interface a Dispatcher may implement to send failure
// notifications directly, bypassing the agent runner. If the dispatcher does
// not implement Alerter, the scheduler falls back to Dispatch.
type Alerter interface {
	Alert(ctx context.Context, p Payload) error
}

// Scheduler handles the lifecycle of scheduled jobs.
type Scheduler struct {
	mu               sync.RWMutex
	storePath        string
	itemsDir         string
	dispatcher       Dispatcher
	pollInterval     time.Duration
	jobTimeout       time.Duration
	store            *Store
	lastMtime        int64
	lastSize         int64
	lastModularMtime int64
	lastReloadErr    error
	lastReloadErrAt  time.Time
	clock            Clock
}

// NewScheduler creates a new background scheduler.
func NewScheduler(storePath, itemsDir string, dispatcher Dispatcher) *Scheduler {
	s := &Scheduler{
		storePath:    storePath,
		itemsDir:     itemsDir,
		dispatcher:   dispatcher,
		pollInterval: 30 * time.Second, // default polling interval
		jobTimeout:   10 * time.Minute,
		clock:        RealClock(),
	}

	// Initialize file tracking state and load initial store
	if info, err := os.Stat(storePath); err == nil {
		s.lastMtime = info.ModTime().UnixNano()
		s.lastSize = info.Size()
		if data, err := os.ReadFile(storePath); err == nil {
			var store Store
			if err := store.DecodeJSON(data); err == nil {
				s.store = &store
			}
		}
	}

	return s
}

// Jobs returns a copy of the current list of jobs.
func (s *Scheduler) Jobs() []Job {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.store == nil {
		return nil
	}
	jobs := make([]Job, len(s.store.Jobs))
	copy(jobs, s.store.Jobs)
	return jobs
}

// WithJobTimeout sets the per-job execution timeout.
// If d is 0, jobs have no deadline.
func (s *Scheduler) WithJobTimeout(d time.Duration) *Scheduler {
	s.jobTimeout = d
	return s
}

// WithClock sets a custom clock for testing or specialized timing.
func (s *Scheduler) WithClock(c Clock) *Scheduler {
	s.clock = c
	return s
}

// ComputeNextRun calculates the next execution time in milliseconds.
// Ported from _compute_next_run in service.py.
func ComputeNextRun(s Schedule, nowMS int64) int64 {
	switch s.Kind {
	case KindAt:
		return computeNextRunAt(s, nowMS)
	case KindEvery:
		return computeNextRunEvery(s, nowMS)
	case KindCron:
		return computeNextRunCron(s, nowMS)
	}
	return 0
}

func computeNextRunAt(s Schedule, nowMS int64) int64 {
	if s.AtMS != nil && *s.AtMS > nowMS {
		return *s.AtMS
	}
	return 0
}

func computeNextRunEvery(s Schedule, nowMS int64) int64 {
	if s.EveryMS != nil && *s.EveryMS > 0 {
		return nowMS + *s.EveryMS
	}
	return 0
}

func computeNextRunCron(s Schedule, nowMS int64) int64 {
	if s.Expr == "" {
		return 0
	}
	loc := time.UTC
	if s.TZ != "" {
		if l, err := time.LoadLocation(s.TZ); err == nil {
			loc = l
		}
	}
	parser := robfigcron.NewParser(robfigcron.Minute | robfigcron.Hour | robfigcron.Dom | robfigcron.Month | robfigcron.Dow)
	schedule, err := parser.Parse(s.Expr)
	if err != nil {
		slog.Warn("KindCron: invalid cron expression", slog.String("expr", s.Expr), logattr.Err(err))
		return 0
	}
	now := time.UnixMilli(nowMS).In(loc)
	return schedule.Next(now).UnixMilli()
}

// Run starts the polling loop.
func (s *Scheduler) Run(ctx context.Context) error {
	slog.Info("cron: starting scheduler", "poll_interval", s.pollInterval)

	for {
		select {
		case <-ctx.Done():
			return fmt.Errorf("scheduler run: %w", ctx.Err())
		case <-s.clock.After(s.pollInterval):
			if err := s.poll(ctx); err != nil {
				slog.Error("cron: poll error", logattr.Err(err))
			}
		}
	}
}

func (s *Scheduler) poll(ctx context.Context) error {
	s.mu.Lock()
	s.reloadJobsJSON()
	s.reloadModularJobs()

	if s.store == nil {
		s.mu.Unlock()
		return nil
	}

	nowMS := s.clock.Now().UnixMilli()
	due, changed := s.identifyDueJobs(nowMS)

	if len(due) == 0 {
		if changed {
			s.saveStore()
		}
		s.mu.Unlock()
		return nil
	}

	if s.dispatcher == nil {
		for _, dj := range due {
			s.store.Jobs[dj.index].State.NextRunAtMS = ComputeNextRun(dj.sched, nowMS)
		}
		s.saveStore()
		s.mu.Unlock()
		return nil
	}
	s.mu.Unlock()

	results := s.runJobsConcurrently(ctx, due)

	s.mu.Lock()
	// Anchor the next run to when the dispatch actually finished, not the
	// poll-start nowMS. A job that ran longer than its interval would otherwise
	// be scheduled in the past and re-fire back-to-back on the next poll.
	completionMS := s.clock.Now().UnixMilli()
	for _, r := range results {
		if r.err != nil {
			s.store.Jobs[r.index].State.FailureCount++
		} else {
			s.store.Jobs[r.index].State.SuccessCount++
		}
		s.store.Jobs[r.index].State.NextRunAtMS = ComputeNextRun(s.store.Jobs[r.index].Schedule, completionMS)
	}
	s.saveStore()
	s.mu.Unlock()

	return nil
}

func (s *Scheduler) reloadJobsJSON() {
	info, err := os.Stat(s.storePath)
	if err != nil {
		if s.lastMtime != 0 {
			s.recordReloadError(fmt.Errorf("stat jobs.json: %w", err))
		}
		s.checkPersistentReloadFailure()
		return
	}

	if !ShouldReload(info.ModTime().UnixNano(), s.lastMtime, info.Size(), s.lastSize) {
		s.checkPersistentReloadFailure()
		return
	}

	slog.Debug("cron: jobs.json modified externally, reloading")
	data, err := os.ReadFile(s.storePath)
	if err != nil {
		s.recordReloadError(fmt.Errorf("read jobs.json: %w", err))
	} else {
		var newStore Store
		if err := newStore.DecodeJSON(data); err != nil {
			s.recordReloadError(fmt.Errorf("decode jobs.json: %w", err))
		} else {
			s.store = &newStore
			s.lastMtime = info.ModTime().UnixNano()
			s.lastSize = info.Size()
			s.clearReloadError()
		}
	}
	s.checkPersistentReloadFailure()
}

func (s *Scheduler) checkPersistentReloadFailure() {
	if s.lastReloadErr != nil && s.clock.Now().Sub(s.lastReloadErrAt) >= 5*time.Minute {
		slog.Warn("cron: persistent jobs.json reload failure",
			logattr.Err(s.lastReloadErr),
			slog.Time("failed_at", s.lastReloadErrAt))
		s.lastReloadErrAt = s.clock.Now()
	}
}

func (s *Scheduler) reloadModularJobs() {
	if s.itemsDir == "" {
		return
	}

	changed, newMtime := DetectModularChange(s.itemsDir, s.lastModularMtime)
	if !changed {
		return
	}

	modularJobs, err := LoadModularJobs(s.itemsDir)
	if err != nil {
		slog.Warn("cron: failed to load modular jobs", logattr.Err(err))
		return
	}

	stateCache := make(map[string]JobState)
	if s.store != nil {
		for _, j := range s.store.Jobs {
			stateCache[j.ID] = j.State
		}
	}
	if s.store == nil {
		s.store = &Store{}
	}
	s.store.Jobs = MergeModularJobs(s.store.Jobs, modularJobs, stateCache)
	s.lastModularMtime = newMtime
	slog.Info("cron: loaded modular jobs", "count", len(modularJobs))
}

// dueJob captures the state needed to dispatch a single job concurrently.
type dueJob struct {
	index   int
	id      string
	name    string
	payload Payload
	sched   Schedule
}

type dispatchResult struct {
	index int
	err   error
}

func (s *Scheduler) identifyDueJobs(nowMS int64) ([]dueJob, bool) {
	changed := false
	var due []dueJob

	for i, job := range s.store.Jobs {
		if !job.Enabled {
			continue
		}

		if job.State.NextRunAtMS == 0 {
			s.store.Jobs[i].State.NextRunAtMS = ComputeNextRun(job.Schedule, nowMS)
			slog.Info("cron: scheduled new job", "id", job.ID, "nextRunAt", time.UnixMilli(s.store.Jobs[i].State.NextRunAtMS))
			changed = true
			continue
		}

		if job.State.NextRunAtMS > 0 && nowMS >= job.State.NextRunAtMS {
			slog.Info("cron: triggering job", "id", job.ID, "name", job.Name)
			s.store.Jobs[i].State.RunCount++
			s.store.Jobs[i].State.LastRunAtMS = nowMS
			due = append(due, dueJob{
				index:   i,
				id:      job.ID,
				name:    job.Name,
				payload: job.Payload,
				sched:   job.Schedule,
			})
			changed = true
		}
	}
	return due, changed
}

func (s *Scheduler) runJobsConcurrently(ctx context.Context, due []dueJob) []dispatchResult {
	resultCh := make(chan dispatchResult, len(due))
	var wg sync.WaitGroup
	for _, dj := range due {
		wg.Add(1)
		go func(dj dueJob) {
			defer wg.Done()
			err := s.executeJob(ctx, dj)
			resultCh <- dispatchResult{index: dj.index, err: err}
		}(dj)
	}
	wg.Wait()
	close(resultCh)

	results := make([]dispatchResult, 0, len(due))
	for r := range resultCh {
		results = append(results, r)
	}
	return results
}

func (s *Scheduler) executeJob(ctx context.Context, dj dueJob) error {
	jobCtx := ctx
	var cancel context.CancelFunc
	if s.jobTimeout > 0 {
		jobCtx, cancel = context.WithTimeout(ctx, s.jobTimeout)
		defer cancel()
	}

	p := dj.payload
	p.ID = dj.id
	err := s.dispatcher.Dispatch(jobCtx, p)
	if err != nil {
		slog.Error("cron: job dispatch failed", slog.String("id", dj.id), logattr.Err(err))
		s.sendFailureAlert(ctx, dj, err)
		return fmt.Errorf("dispatch job: %w", err)
	}
	return nil
}

func (s *Scheduler) sendFailureAlert(ctx context.Context, dj dueJob, err error) {
	var alreadyNotified *AlreadyNotifiedError
	if errors.As(err, &alreadyNotified) {
		slog.Info("cron: failure notification already sent by dispatcher, skipping alert",
			slog.String("id", dj.id))
		return
	}
	alert := Payload{
		Channel: dj.payload.Channel,
		To:      dj.payload.To,
		Message: fmt.Sprintf("Job %q failed: %v", dj.name, err),
	}
	if a, ok := s.dispatcher.(Alerter); ok {
		if alertErr := a.Alert(ctx, alert); alertErr != nil {
			slog.Error("cron: job failure alert could not be sent", slog.String("id", dj.id), logattr.Err(alertErr))
		}
	} else {
		if alertErr := s.dispatcher.Dispatch(ctx, alert); alertErr != nil {
			slog.Error("cron: job failure alert could not be sent", slog.String("id", dj.id), logattr.Err(alertErr))
		}
	}
}

func (s *Scheduler) saveStore() {
	data, err := s.store.EncodeJSON()
	if err != nil {
		slog.Error("cron: failed to encode jobs store", logattr.Err(err))
		return
	}
	if err := state.WriteFileAtomic(s.storePath, data, 0o600); err != nil {
		slog.Error("cron: failed to save jobs store", logattr.Err(err))
		return
	}
	if info, err := os.Stat(s.storePath); err == nil {
		s.lastMtime = info.ModTime().UnixNano()
		s.lastSize = info.Size()
	}
}

func (s *Scheduler) recordReloadError(err error) {
	if s.lastReloadErr == nil {
		slog.Error("cron: jobs.json reload failed", logattr.Err(err))
		s.lastReloadErr = err
		s.lastReloadErrAt = s.clock.Now()
	} else {
		// Update the error but keep the original timestamp for the 5m warning
		s.lastReloadErr = err
	}
}

func (s *Scheduler) clearReloadError() {
	if s.lastReloadErr != nil {
		slog.Info("cron: jobs.json reload recovered")
		s.lastReloadErr = nil
		s.lastReloadErrAt = time.Time{}
	}
}
