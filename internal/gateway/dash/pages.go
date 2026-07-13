package dash

import (
	"log/slog"
	"net/http"
	"time"

	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/doctor"
)

func (h *Handler) handleHome(w http.ResponseWriter, _ *http.Request) {
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

func (h *Handler) render(w http.ResponseWriter, layout, content string, data any) {
	t, ok := h.pages[content]
	if !ok {
		http.Error(w, "Template not found", http.StatusInternalServerError)
		return
	}

	// We execute the layout, which includes the content define from the page template.
	if err := t.ExecuteTemplate(w, layout, data); err != nil {
		slog.Error("dash: render error", "err", err, "layout", layout, "content", content)
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}
