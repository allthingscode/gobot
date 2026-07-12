// Package dash implements the web management dashboard.
package dash

import (
	"context"
	"embed"
	"html/template"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/cron"
	"github.com/allthingscode/gobot/internal/dashboard"
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
		"metrics.html",
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
	case strings.HasPrefix(path, "/metrics"):
		h.handleMetrics(w, r)
	case strings.HasPrefix(path, "/cron"):
		h.handleCron(w, r)
	case strings.HasPrefix(path, "/logs"):
		h.handleLogs(w, r)
	default:
		http.Redirect(w, r, "/dash/", http.StatusFound)
	}
}
