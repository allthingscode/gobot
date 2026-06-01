// Package dash implements the web management dashboard.
package dash

import (
	"context"
	"embed"
	"fmt"
	"html/template"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/cron"
	"github.com/allthingscode/gobot/internal/dashboard"
	"github.com/allthingscode/gobot/internal/doctor"
)

//go:embed templates/*.html
var templatesFS embed.FS

//nolint:gochecknoglobals // Immutable: tracks process start time for uptime calculation
var startTime = time.Now()

const partialQueryValue = "true"

// Resources provides access to system managers for the dashboard.
type Resources struct {
	Config      *config.Config
	Checkpoints *agentctx.CheckpointManager
	Memory      MemoryProvider
	Cron        CronProvider
	Hub         LogHub
	Version     string
}

// MemoryProvider abstracts memory statistics and search.
type MemoryProvider interface {
	Stats() (int, error)
	Search(ctx context.Context, query, sessionKey string, limit int) ([]map[string]any, error)
}

// CronProvider abstracts the cron scheduler.
type CronProvider interface {
	Jobs() []cron.Job
}

// LogHub abstracts the log broadcast hub.
type LogHub interface {
	Subscribe() (chan *dashboard.LogEntry, []*dashboard.LogEntry)
	Unsubscribe(sub chan *dashboard.LogEntry)
}

// Handler serves the dashboard pages and partials.
type Handler struct {
	res   Resources
	pages map[string]*template.Template
}

// NewHandler creates a new dashboard handler.
func NewHandler(res Resources) *Handler {
	pages := make(map[string]*template.Template)

	funcMap := template.FuncMap{
		"msToTime": func(ms int64) string {
			if ms <= 0 {
				return "-"
			}
			return time.UnixMilli(ms).Format("2006-01-02 15:04:05")
		},
	}

	// List of page templates to compile with layout
	pageFiles := []string{
		"home.html",
		"sessions.html",
		"memory.html",
		"cron.html",
		"doctor.html",
		"logs.html",
	}

	for _, page := range pageFiles {
		t := template.New(page).Funcs(funcMap)
		t, err := t.ParseFS(templatesFS, "templates/layout.html", "templates/"+page)
		if err != nil {
			slog.Error("dash: failed to parse template", "page", page, "err", err)
		} else {
			pages[page] = t
		}
	}

	return &Handler{
		res:   res,
		pages: pages,
	}
}

// ServeHTTP implements the http.Handler interface.
func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/dash")
	if path == "" || path == "/" {
		h.handleHome(w, r)
		return
	}
	h.routePath(path, w, r)
}

func (h *Handler) routePath(path string, w http.ResponseWriter, r *http.Request) {
	switch {
	case strings.HasPrefix(path, "/doctor"):
		h.handleDoctor(w, r)
	case strings.HasPrefix(path, "/sessions"):
		h.handleSessions(w, r)
	case strings.HasPrefix(path, "/memory/search"):
		h.handleMemorySearch(w, r)
	case strings.HasPrefix(path, "/memory"):
		h.handleMemory(w, r)
	case strings.HasPrefix(path, "/cron"):
		h.handleCron(w, r)
	case strings.HasPrefix(path, "/logs"):
		h.handleLogs(w, r)
	default:
		http.Redirect(w, r, "/dash/", http.StatusFound)
	}
}

func (h *Handler) handleHome(w http.ResponseWriter, r *http.Request) {
	data := struct {
		ActiveNav string
		Uptime    string
		Version   string
	}{
		ActiveNav: "home",
		Uptime:    time.Since(startTime).Round(time.Second).String(),
		Version:   h.res.Version,
	}

	h.render(w, "layout.html", "home.html", data)
}

func (h *Handler) handleDoctor(w http.ResponseWriter, r *http.Request) {
	// For now, skip live probes to keep dashboard fast
	results := doctor.GetResults(h.res.Config, nil)

	data := struct {
		ActiveNav string
		Results   []doctor.Result
		Timestamp string
	}{
		ActiveNav: "doctor",
		Results:   results,
		Timestamp: time.Now().Format("15:04:05"),
	}

	if r.URL.Query().Get("partial") == partialQueryValue {
		t, ok := h.pages["doctor.html"]
		if !ok {
			http.Error(w, "Template not found", http.StatusInternalServerError)
			return
		}
		if err := t.ExecuteTemplate(w, "doctor_results", data); err != nil {
			slog.Error("dash: render error", "err", err)
			http.Error(w, err.Error(), http.StatusInternalServerError)
		}
		return
	}

	h.render(w, "layout.html", "doctor.html", data)
}

func (h *Handler) handleSessions(w http.ResponseWriter, r *http.Request) {
	var sessions []agentctx.ResumableThread
	var err error

	if h.res.Checkpoints != nil {
		sessions, err = h.res.Checkpoints.ListResumable(r.Context())
		if err != nil {
			slog.Error("dash: failed to list sessions", "err", err)
		}
	}

	data := struct {
		ActiveNav string
		Sessions  []agentctx.ResumableThread
	}{
		ActiveNav: "sessions",
		Sessions:  sessions,
	}

	h.render(w, "layout.html", "sessions.html", data)
}

func (h *Handler) handleMemory(w http.ResponseWriter, _ *http.Request) {
	count := -1
	var err error

	if h.res.Memory != nil {
		count, err = h.res.Memory.Stats()
		if err != nil {
			slog.Error("dash: failed to get memory stats", "err", err)
		}
	}

	data := struct {
		ActiveNav string
		Count     int
		Query     string
		Results   []map[string]any
	}{
		ActiveNav: "memory",
		Count:     count,
		Query:     "",
	}

	h.render(w, "layout.html", "memory.html", data)
}

func (h *Handler) handleMemorySearch(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query().Get("q")
	var results []map[string]any
	var err error

	if h.res.Memory != nil && query != "" {
		results, err = h.res.Memory.Search(r.Context(), query, "all", 10)
		if err != nil {
			slog.Error("dash: memory search failed", "err", err)
		}
	}

	data := struct {
		ActiveNav string
		Query     string
		Results   []map[string]any
	}{
		ActiveNav: "memory",
		Query:     query,
		Results:   results,
	}

	if r.URL.Query().Get("partial") == partialQueryValue {
		t, ok := h.pages["memory.html"]
		if !ok {
			http.Error(w, "Template not found", http.StatusInternalServerError)
			return
		}
		if err := t.ExecuteTemplate(w, "search_results", data); err != nil {
			slog.Error("dash: render error", "err", err)
			http.Error(w, err.Error(), http.StatusInternalServerError)
		}
		return
	}

	h.render(w, "layout.html", "memory.html", data)
}

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

const logTailLines = 200

func (h *Handler) handleLogs(w http.ResponseWriter, r *http.Request) {
	level := r.URL.Query().Get("level")
	content := h.hubLogTail(logTailLines, level)
	if content == "" {
		// No live hub wired (or empty buffer): fall back to the rotated log file.
		logPath := h.res.Config.LogPath("gobot.log")
		tail, err := tailFileLines(logPath, logTailLines, level)
		if err != nil {
			slog.Warn("dash: failed to read logs", "path", logPath, "err", err)
			tail = "log file unavailable"
		}
		content = tail
	}

	data := struct {
		ActiveNav string
		LogTail   string
		Level     string
	}{
		ActiveNav: "logs",
		LogTail:   content,
		Level:     levelFilter(level),
	}
	if r.URL.Query().Get("partial") == partialQueryValue {
		t, ok := h.pages["logs.html"]
		if !ok {
			http.Error(w, "Template not found", http.StatusInternalServerError)
			return
		}
		if err := t.ExecuteTemplate(w, "log_tail", data); err != nil {
			slog.Error("dash: render error", "err", err)
			http.Error(w, err.Error(), http.StatusInternalServerError)
		}
		return
	}

	h.render(w, "layout.html", "logs.html", data)
}

// canonicalLevels are the four levels the /logs filter recognizes. A requested
// level outside this set (or empty) means "no filter" — show all entries.
//
//nolint:gochecknoglobals // Immutable lookup table for level-filter validation.
var canonicalLevels = map[string]struct{}{
	"DEBUG": {},
	"INFO":  {},
	"WARN":  {},
	"ERROR": {},
}

// levelFilter normalizes a requested ?level value to a canonical uppercase
// token, or "" when no filter should apply (empty/unknown ⇒ show all).
func levelFilter(requested string) string {
	upper := strings.ToUpper(strings.TrimSpace(requested))
	if _, ok := canonicalLevels[upper]; ok {
		return upper
	}
	return ""
}

// levelMatches reports whether a stored level token matches the canonical
// filter. The match is prefix-tolerant on the canonical token so future
// offset levels (e.g. "INFO+2") still match "INFO".
func levelMatches(stored, filter string) bool {
	if filter == "" {
		return true
	}
	return strings.HasPrefix(strings.ToUpper(stored), filter)
}

// hubLogTail reads the last maxLines entries from the live log hub's ring
// buffer and formats them for display. When level is a canonical token the
// entries are filtered (case-insensitively) before truncation, so up to
// maxLines matching lines are shown. It returns "" when no hub is wired so
// the caller can fall back to file tailing.
func (h *Handler) hubLogTail(maxLines int, level string) string {
	if h.res.Hub == nil {
		return ""
	}
	sub, backlog := h.res.Hub.Subscribe()
	if sub != nil {
		h.res.Hub.Unsubscribe(sub)
	}
	if len(backlog) == 0 {
		return ""
	}
	backlog = filterByLevel(backlog, levelFilter(level))
	if len(backlog) > maxLines {
		backlog = backlog[len(backlog)-maxLines:]
	}
	return formatLogEntries(backlog)
}

// filterByLevel returns only the entries whose level matches filter, skipping
// nil entries. When filter is "" the input is returned unchanged.
func filterByLevel(backlog []*dashboard.LogEntry, filter string) []*dashboard.LogEntry {
	if filter == "" {
		return backlog
	}
	filtered := backlog[:0:0]
	for _, e := range backlog {
		if e != nil && levelMatches(e.Level, filter) {
			filtered = append(filtered, e)
		}
	}
	return filtered
}

// formatLogEntries renders entries as newline-separated "ts level message"
// lines, skipping nil entries, with no trailing newline.
func formatLogEntries(backlog []*dashboard.LogEntry) string {
	var sb strings.Builder
	for _, e := range backlog {
		if e == nil {
			continue
		}
		sb.WriteString(e.Timestamp.Format("2006-01-02 15:04:05"))
		sb.WriteByte(' ')
		sb.WriteString(e.Level)
		sb.WriteByte(' ')
		sb.WriteString(e.Message)
		sb.WriteByte('\n')
	}
	return strings.TrimRight(sb.String(), "\n")
}

func (h *Handler) render(w http.ResponseWriter, layout, content string, data any) {
	t, ok := h.pages[content]
	if !ok {
		http.Error(w, "Template not found", http.StatusInternalServerError)
		return
	}

	// We execute the layout, which will include the 'content' define from the specific page template.
	if err := t.ExecuteTemplate(w, layout, data); err != nil {
		slog.Error("dash: render error", "err", err, "layout", layout, "content", content)
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

// AuthMiddleware wraps a handler with basic token-based authentication.
func AuthMiddleware(token string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if token == "" {
			// If no token is configured, allow access (or we could default to blocking)
			next.ServeHTTP(w, r)
			return
		}

		// Check for token in 'Authorization: Bearer <token>' header or 'token' query param
		authHeader := r.Header.Get("Authorization")
		provided := ""
		if strings.HasPrefix(authHeader, "Bearer ") {
			provided = strings.TrimPrefix(authHeader, "Bearer ")
		} else {
			provided = r.URL.Query().Get("token")
		}

		if provided != token {
			// Also check for 'token' cookie as a fallback for browser access
			if cookie, err := r.Cookie("gobot_token"); err == nil {
				provided = cookie.Value
			}
		}

		if provided != token {
			slog.Warn("dash: unauthorized access attempt", "remote_addr", r.RemoteAddr) //nolint:gosec // G706: remote_addr is safe to log
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}

		next.ServeHTTP(w, r)
	})
}

func tailFileLines(path string, maxLines int, level string) (string, error) {
	if maxLines <= 0 {
		return "", nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read log file %q: %w", path, err)
	}
	text := strings.ReplaceAll(string(data), "\r\n", "\n")
	lines := strings.Split(text, "\n")
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	if filter := levelFilter(level); filter != "" {
		// The text handler renders the level as a "level=LEVEL" attribute;
		// fall back to a token check so the JSON handler's "LEVEL" form also matches.
		needleAttr := "level=" + filter
		filtered := lines[:0:0]
		for _, ln := range lines {
			upper := strings.ToUpper(ln)
			if strings.Contains(upper, needleAttr) || strings.Contains(upper, " "+filter+" ") {
				filtered = append(filtered, ln)
			}
		}
		lines = filtered
	}
	if len(lines) > maxLines {
		lines = lines[len(lines)-maxLines:]
	}
	return strings.Join(lines, "\n"), nil
}
