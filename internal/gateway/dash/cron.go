package dash

import (
	"net/http"
	"time"

	"github.com/allthingscode/gobot/internal/cron"
)

type cronTaskView struct {
	Name      string
	Schedule  string
	LastRunMS int64
	NextRunMS int64
	Status    string
	Live      bool
}

func (h *Handler) handleCron(w http.ResponseWriter, _ *http.Request) {
	tasks := h.liveCronTasks()
	live := tasks != nil
	if !live {
		tasks = h.configCronTasks()
	}

	data := struct {
		ActiveNav string
		Live      bool
		Tasks     []cronTaskView
	}{
		ActiveNav: "cron",
		Live:      live,
		Tasks:     tasks,
	}
	h.render(w, "layout.html", "cron.html", data)
}

// liveCronTasks returns the running scheduler's jobs with live state, or nil
// when no CronProvider is wired (in which case the caller falls back to the
// statically configured tasks).
func (h *Handler) liveCronTasks() []cronTaskView {
	if h.res.Cron == nil {
		return nil
	}
	jobs := h.res.Cron.Jobs()
	tasks := make([]cronTaskView, 0, len(jobs))
	for _, job := range jobs {
		tasks = append(tasks, cronTaskView{
			Name:      job.Name,
			Schedule:  describeSchedule(job.Schedule),
			LastRunMS: job.State.LastRunAtMS,
			NextRunMS: job.State.NextRunAtMS,
			Status:    jobStatus(job),
			Live:      true,
		})
	}
	return tasks
}

func (h *Handler) configCronTasks() []cronTaskView {
	nowMS := time.Now().UnixMilli()
	tasks := make([]cronTaskView, 0, len(h.res.Config.Cron.Tasks))
	for _, task := range h.res.Config.Cron.Tasks {
		nextRun := cron.ComputeNextRun(cron.Schedule{Kind: cron.KindCron, Expr: task.Schedule}, nowMS)
		tasks = append(tasks, cronTaskView{
			Name:      task.Name,
			Schedule:  task.Schedule,
			NextRunMS: nextRun,
			Status:    "configured",
		})
	}
	return tasks
}

// jobStatus summarizes a job's last outcome from its run counters.
func jobStatus(job cron.Job) string {
	if !job.Enabled {
		return "disabled"
	}
	if job.State.RunCount == 0 {
		return "pending"
	}
	if job.State.LastRunAtMS > 0 && job.State.FailureCount > job.State.SuccessCount {
		return "failed"
	}
	return "ok"
}

// describeSchedule renders a human-readable schedule for the dashboard.
func describeSchedule(s cron.Schedule) string {
	switch s.Kind {
	case cron.KindCron:
		return s.Expr
	case cron.KindEvery:
		if s.EveryMS != nil {
			return "every " + (time.Duration(*s.EveryMS) * time.Millisecond).String()
		}
		return "every"
	case cron.KindAt:
		if s.AtMS != nil {
			return "at " + time.UnixMilli(*s.AtMS).Format("2006-01-02 15:04:05")
		}
		return "at"
	default:
		return string(s.Kind)
	}
}
