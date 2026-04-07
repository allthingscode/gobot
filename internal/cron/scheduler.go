package cron

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"sync"
	"time"

	robfigcron "github.com/robfig/cron/v3"
)

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
	storePath        string
	itemsDir         string
	dispatcher       Dispatcher
	pollInterval     time.Duration
	jobTimeout       time.Duration
	store            *Store
	lastMtime        int64
	lastSize         int64
	lastModularMtime float64
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
		if s.AtMS != nil && *s.AtMS > nowMS {
			return *s.AtMS
		}
	case KindEvery:
		if s.EveryMS != nil && *s.EveryMS > 0 {
			return nowMS + *s.EveryMS
		}
	case KindCron:
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
			slog.Warn("KindCron: invalid cron expression", "expr", s.Expr, "err", err)
			return 0
		}
		now := time.UnixMilli(nowMS).In(loc)
		return schedule.Next(now).UnixMilli()
	}
	return 0
}

// Run starts the polling loop.
func (s *Scheduler) Run(ctx context.Context) error {
	slog.Info("Starting cron scheduler", "poll_interval", s.pollInterval)

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-s.clock.After(s.pollInterval):
			if err := s.poll(ctx); err != nil {
				slog.Error("Cron poll error", "error", err)
			}
		}
	}
}

func (s *Scheduler) poll(ctx context.Context) error {
	// 1. Check for reloads of jobs.json
	info, err := os.Stat(s.storePath)
	if err == nil {
		if ShouldReload(info.ModTime().UnixNano(), s.lastMtime, info.Size(), s.lastSize) {
			slog.Debug("Cron: jobs.json modified externally, reloading")
			data, err := os.ReadFile(s.storePath)
			if err == nil {
				var newStore Store
				if err := newStore.DecodeJSON(data); err == nil {
					s.store = &newStore
					s.lastMtime = info.ModTime().UnixNano()
					s.lastSize = info.Size()
				}
			}
		}
	}

	// 2. Check for modular job changes.
	if s.itemsDir != "" {
		if changed, newMtime := DetectModularChange(s.itemsDir, s.lastModularMtime); changed {
			modularJobs, err := LoadModularJobs(s.itemsDir)
			if err != nil {
				slog.Warn("Cron: failed to load modular jobs", "err", err)
			} else {
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
				slog.Info("Cron: loaded modular jobs", "count", len(modularJobs))
			}
		}
	}

	// 3. Trigger due jobs
	nowMS := s.clock.Now().UnixMilli()
	if s.store == nil {
		return nil
	}

	// dueJob captures the state needed to dispatch a single job concurrently.
	type dueJob struct {
		index   int
		id      string
		name    string
		payload Payload
		sched   Schedule
	}

	changed := false
	var due []dueJob

	for i, job := range s.store.Jobs {
		if !job.Enabled {
			continue
		}

		// Initialize NextRunAtMS on first load (new jobs have zero value).
		if job.State.NextRunAtMS == 0 {
			s.store.Jobs[i].State.NextRunAtMS = ComputeNextRun(job.Schedule, nowMS)
			slog.Info("Cron: scheduled new job", "id", job.ID, "nextRunAt", time.UnixMilli(s.store.Jobs[i].State.NextRunAtMS))
			changed = true
			continue
		}

		if job.State.NextRunAtMS > 0 && nowMS >= job.State.NextRunAtMS {
			slog.Info("Triggering job", "id", job.ID, "name", job.Name)
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

	// Fan-out: dispatch all due jobs concurrently, then apply results.
	if len(due) > 0 && s.dispatcher != nil {
		type dispatchResult struct {
			index int
			err   error
		}
		results := make(chan dispatchResult, len(due))
		var wg sync.WaitGroup
		for _, dj := range due {
			wg.Add(1)
			go func(dj dueJob) {
				defer wg.Done()

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
					slog.Error("Job dispatch failed", "id", dj.id, "error", err)
					alert := Payload{
						Channel: dj.payload.Channel,
						To:      dj.payload.To,
						Message: fmt.Sprintf("Job %q failed: %v", dj.name, err),
					}
					if a, ok := s.dispatcher.(Alerter); ok {
						if alertErr := a.Alert(ctx, alert); alertErr != nil {
							slog.Error("Job failure alert could not be sent", "id", dj.id, "err", alertErr)
						}
					} else {
						if alertErr := s.dispatcher.Dispatch(ctx, alert); alertErr != nil {
							slog.Error("Job failure alert could not be sent", "id", dj.id, "err", alertErr)
						}
					}
				}
				results <- dispatchResult{index: dj.index, err: err}
			}(dj)
		}
		wg.Wait()
		close(results)

		for r := range results {
			if r.err != nil {
				s.store.Jobs[r.index].State.FailureCount++
			} else {
				s.store.Jobs[r.index].State.SuccessCount++
			}
			s.store.Jobs[r.index].State.NextRunAtMS = ComputeNextRun(s.store.Jobs[r.index].Schedule, nowMS)
		}
	} else if len(due) > 0 {
		// No dispatcher configured: still advance the schedule.
		for _, dj := range due {
			s.store.Jobs[dj.index].State.NextRunAtMS = ComputeNextRun(dj.sched, nowMS)
		}
	}

	// 4. Save store if changes occurred
	if changed {
		data, err := s.store.EncodeJSON()
		if err == nil {
			_ = os.WriteFile(s.storePath, data, 0o600)
			// Update stats to avoid immediate reload
			if info, err := os.Stat(s.storePath); err == nil {
				s.lastMtime = info.ModTime().UnixNano()
				s.lastSize = info.Size()
			}
		}
	}

	return nil
}
