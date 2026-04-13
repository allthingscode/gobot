// Package dash implements the web management dashboard.
package dash

import (
	"embed"
	"html/template"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/doctor"
)

//go:embed templates/*.html
var templatesFS embed.FS

//nolint:gochecknoglobals // Immutable: tracks process start time for uptime calculation
var startTime = time.Now()

// Resources provides access to system managers for the dashboard.
type Resources struct {
	Config      *config.Config
	Checkpoints *context.CheckpointManager
	Memory      MemoryStatsProvider
	Version     string
}

// MemoryStatsProvider abstracts memory statistics.
type MemoryStatsProvider interface {
	Stats() (int, error)
}

// Handler serves the dashboard pages and partials.
type Handler struct {
	res   Resources
	pages map[string]*template.Template
}

// NewHandler creates a new dashboard handler.
func NewHandler(res Resources) *Handler {
	pages := make(map[string]*template.Template)

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
		t, err := template.ParseFS(templatesFS, "templates/layout.html", "templates/"+page)
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
	// Simple routing
	path := strings.TrimPrefix(r.URL.Path, "/dash")
	if path == "" || path == "/" {
		h.handleHome(w, r)
		return
	}

	switch {
	case strings.HasPrefix(path, "/doctor"):
		h.handleDoctor(w, r)
	case strings.HasPrefix(path, "/sessions"):
		h.handleSessions(w, r)
	case strings.HasPrefix(path, "/memory"):
		h.handleMemory(w, r)
	case strings.HasPrefix(path, "/cron"):
		h.handleCron(w, r)
	case strings.HasPrefix(path, "/logs"):
		h.handleLogs(w, r)
	default:
		// Temporary: redirect unknown dashboard paths to home
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

	if r.URL.Query().Get("partial") == "true" {
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

func (h *Handler) handleSessions(w http.ResponseWriter, _ *http.Request) {
	var sessions []context.ResumableThread
	var err error

	if h.res.Checkpoints != nil {
		sessions, err = h.res.Checkpoints.ListResumable()
		if err != nil {
			slog.Error("dash: failed to list sessions", "err", err)
		}
	}

	data := struct {
		ActiveNav string
		Sessions  []context.ResumableThread
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
	}{
		ActiveNav: "memory",
		Count:     count,
	}

	h.render(w, "layout.html", "memory.html", data)
}

func (h *Handler) handleCron(w http.ResponseWriter, _ *http.Request) {
	data := struct {
		ActiveNav string
	}{
		ActiveNav: "cron",
	}
	h.render(w, "layout.html", "cron.html", data)
}

func (h *Handler) handleLogs(w http.ResponseWriter, _ *http.Request) {
	data := struct {
		ActiveNav string
	}{
		ActiveNav: "logs",
	}
	h.render(w, "layout.html", "logs.html", data)
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
			slog.Warn("dash: unauthorized access attempt", "remote_addr", r.RemoteAddr)
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}

		next.ServeHTTP(w, r)
	})
}
