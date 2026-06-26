package agent

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	agentctx "github.com/allthingscode/gobot/internal/context"
)

// SessionLogger writes conversation transcripts to durable storage.
// Implementations must be safe for concurrent use.
type SessionLogger interface {
	Log(sessionKey string, iteration int, messages []agentctx.StrategicMessage) error
}

// maxSessionAgeDays is the retention window for dated session transcript
// directories. Directories older than this (by date) are pruned on each Log
// call. Durable conversation state lives in checkpoints.db; these .md files are
// a human-readable debug aid, not the source of truth.
const maxSessionAgeDays = 14

// safeKey replaces characters that are invalid in filenames with underscores.
var safeKeyRe = regexp.MustCompile(`[^a-zA-Z0-9_\-]`)

func sanitizeKey(s string) string {
	return safeKeyRe.ReplaceAllString(s, "_")
}

// MarkdownLogger writes one .md file per SaveSnapshot call under:
//
//	{sessionsDir}/YYYY-MM-DD/<session_key>_<timestamp>.md
//
// Each file contains the full conversation history formatted as Markdown.
type MarkdownLogger struct {
	sessionsDir string
}

// NewMarkdownLogger creates a MarkdownLogger that writes under
// {storageRoot}/workspace/sessions/.
func NewMarkdownLogger(storageRoot string) *MarkdownLogger {
	return &MarkdownLogger{
		sessionsDir: filepath.Join(storageRoot, "workspace", "sessions"),
	}
}

// Log writes the full conversation history to a dated markdown file.
// Errors are non-fatal in normal usage — the caller may log and continue.
func (l *MarkdownLogger) Log(sessionKey string, iteration int, messages []agentctx.StrategicMessage) error {
	now := time.Now().UTC()
	dateDir := now.Format("2006-01-02")
	ts := now.Format("20060102T150405Z")
	safeKey := sanitizeKey(sessionKey)
	filename := fmt.Sprintf("%s_%s.md", safeKey, ts)

	dir := filepath.Join(l.sessionsDir, dateDir)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("MarkdownLogger: mkdir %s: %w", dir, err)
	}

	path := filepath.Join(dir, filename)
	content := renderMarkdown(sessionKey, iteration, messages, now)
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		return fmt.Errorf("MarkdownLogger: write %s: %w", path, err)
	}

	// Prune is best-effort: the transcript above is already durably written, so
	// a cleanup failure must not turn a successful Log into an error.
	_ = l.pruneOldSessions(now)
	return nil
}

// pruneOldSessions removes dated session directories under sessionsDir whose
// date is strictly older than maxSessionAgeDays before now. Entries whose names
// do not parse as YYYY-MM-DD are left untouched. now is threaded from the caller
// so pruning is deterministically testable without sleeping.
func (l *MarkdownLogger) pruneOldSessions(now time.Time) error {
	entries, err := os.ReadDir(l.sessionsDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("MarkdownLogger: read sessions dir %s: %w", l.sessionsDir, err)
	}

	cutoff := now.UTC().Truncate(24 * time.Hour).AddDate(0, 0, -maxSessionAgeDays)
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		dirDate, parseErr := time.Parse("2006-01-02", entry.Name())
		if parseErr != nil {
			continue
		}
		if dirDate.Before(cutoff) {
			if rmErr := os.RemoveAll(filepath.Join(l.sessionsDir, entry.Name())); rmErr != nil {
				err = fmt.Errorf("MarkdownLogger: prune %s: %w", entry.Name(), rmErr)
			}
		}
	}
	return err
}

// renderMarkdown produces the file content for a session snapshot.
func renderMarkdown(sessionKey string, iteration int, messages []agentctx.StrategicMessage, ts time.Time) string {
	var sb strings.Builder
	fmt.Fprintf(&sb, "# Session: %s\n", sessionKey)
	fmt.Fprintf(&sb, "**Iteration:** %d  \n", iteration)
	fmt.Fprintf(&sb, "**Saved:** %s\n\n", ts.Format(time.RFC3339))

	for _, msg := range messages {
		fmt.Fprintf(&sb, "---\n\n## %s\n\n", msg.Role)
		if msg.Content == nil {
			sb.WriteString("*(empty)*\n\n")
			continue
		}
		if msg.Content.Str != nil {
			sb.WriteString(*msg.Content.Str)
			sb.WriteString("\n\n")
			continue
		}
		for _, item := range msg.Content.Items {
			switch {
			case item.Text != nil:
				sb.WriteString(item.Text.Text)
				sb.WriteString("\n\n")
			case item.Thinking != nil:
				fmt.Fprintf(&sb, "*[thinking: %s]*\n\n", item.Thinking.Text)
			case item.Image != nil:
				fmt.Fprintf(&sb, "*[image: %s]*\n\n", item.Image.ImageURL.URL)
			case item.Tool != nil:
				fmt.Fprintf(&sb, "*[tool_call: %s(%s)]*\n\n", item.Tool.Function.Name, item.Tool.Function.Arguments)
			}
		}
	}
	return sb.String()
}
