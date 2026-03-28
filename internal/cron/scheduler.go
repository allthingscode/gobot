package cron

import (
	"context"
	"log/slog"
	"os"
	"time"

	robfigcron "github.com/robfig/cron/v3"
)

// Dispatcher defines the interface for sending job messages.
type Dispatcher interface {
	Dispatch(ctx context.Context, p Payload) error
}

// Scheduler handles the lifecycle of scheduled jobs.
type Scheduler struct {
	storePath    string
	itemsDir     string
	dispatcher   Dispatcher
	pollInterval time.Duration
	store        *Store
	lastMtime    int64
	lastSize     int64
	lastModularMtime float64
}

// NewScheduler creates a new background scheduler.
func NewScheduler(storePath, itemsDir string, dispatcher Dispatcher) *Scheduler {
	return &Scheduler{
		storePath:    storePath,
		itemsDir:     itemsDir,
		dispatcher:   dispatcher,
		pollInterval: 30 * time.Second, // default polling interval
	}
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
	ticker := time.NewTicker(s.pollInterval)
	defer ticker.Stop()

	slog.Info("Starting cron scheduler", "poll_interval", s.pollInterval)

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
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
			slog.Info("Cron: jobs.json modified externally, reloading")
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

	// 2. Check for modular changes (HEARTBEAT.md handled in separate logic usually)
	// For now, we focus on the core store.

	// 3. Trigger due jobs
	nowMS := time.Now().UnixNano() / 1e6
	if s.store == nil {
		return nil
	}

	changed := false
	for i, job := range s.store.Jobs {
		if !job.Enabled {
			continue
		}

		if job.State.NextRunAtMS > 0 && nowMS >= job.State.NextRunAtMS {
			slog.Info("Triggering job", "id", job.ID, "name", job.Name)
			
			s.store.Jobs[i].State.RunCount++
			s.store.Jobs[i].State.LastRunAtMS = nowMS
			
			if s.dispatcher != nil {
				if err := s.dispatcher.Dispatch(ctx, job.Payload); err != nil {
					slog.Error("Job dispatch failed", "id", job.ID, "error", err)
					s.store.Jobs[i].State.FailureCount++
				} else {
					s.store.Jobs[i].State.SuccessCount++
				}
			}

			// Schedule next run
			s.store.Jobs[i].State.NextRunAtMS = ComputeNextRun(job.Schedule, nowMS)
			changed = true
		}
	}

	// 4. Save store if changes occurred
	if changed {
		data, err := s.store.EncodeJSON()
		if err == nil {
			_ = os.WriteFile(s.storePath, data, 0644)
			// Update stats to avoid immediate reload
			if info, err := os.Stat(s.storePath); err == nil {
				s.lastMtime = info.ModTime().UnixNano()
				s.lastSize = info.Size()
			}
		}
	}

	return nil
}
