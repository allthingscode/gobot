package dash

import (
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"strings"

	"github.com/allthingscode/gobot/internal/dashboard"
)

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
// level outside this set (or empty) means "no filter" and shows all entries.
//
//nolint:gochecknoglobals // Immutable lookup table for level-filter validation.
var canonicalLevels = map[string]struct{}{
	"DEBUG": {},
	"INFO":  {},
	"WARN":  {},
	"ERROR": {},
}

// levelFilter normalizes a requested ?level value to a canonical uppercase
// token, or "" when no filter should apply.
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
