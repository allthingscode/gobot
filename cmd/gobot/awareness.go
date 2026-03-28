package main

import (
	"log/slog"
	"os"
	"path/filepath"
	"strings"

	"github.com/allthingscode/gobot/internal/google"
	"github.com/allthingscode/gobot/internal/memory"
)

const awarenessMaxJournalChars = 4000

// loadSystemPrompt builds the combined system prompt from SOUL.md (identity),
// AWARENESS.md (operational context), and today's journal continuity block.
// Returns an empty string if no source has content.
func loadSystemPrompt(storageRoot string) string {
	var parts []string

	// SOUL.md — agent identity document. Look next to the binary first,
	// then fall back to the storage workspace. Silently skipped if absent.
	if soulData := loadSoulMD(storageRoot); soulData != "" {
		parts = append(parts, soulData)
	}

	awarenessPath := filepath.Join(storageRoot, "workspace", "AWARENESS.md")
	if data, err := os.ReadFile(awarenessPath); err == nil && len(data) > 0 {
		parts = append(parts, strings.TrimSpace(string(data)))
	}

	if continuity := memory.GetJournalContinuity(storageRoot, awarenessMaxJournalChars); continuity != "" {
		parts = append(parts, continuity)
	}

	// Inject live calendar and tasks — best-effort, never fatal.
	secretsRoot := filepath.Join(storageRoot, "secrets")
	if schedule := loadScheduleContext(secretsRoot); schedule != "" {
		parts = append(parts, schedule)
	}

	return strings.Join(parts, "\n\n")
}

// loadSoulMD reads SOUL.md from .private/ next to the binary (dev) or
// {storageRoot}/workspace/SOUL.md (deployed copy). Returns empty string if not found.
func loadSoulMD(storageRoot string) string {
	candidates := []string{
		// Deployed copy in storage workspace (copy here for production use)
		filepath.Join(storageRoot, "workspace", "SOUL.md"),
	}
	if exe, err := os.Executable(); err == nil {
		dir := filepath.Dir(exe)
		candidates = append([]string{
			// .private/SOUL.md next to the binary (dev environment)
			filepath.Join(dir, ".private", "SOUL.md"),
			// SOUL.md directly next to the binary
			filepath.Join(dir, "SOUL.md"),
		}, candidates...)
	}
	for _, p := range candidates {
		if data, err := os.ReadFile(p); err == nil && len(data) > 0 {
			return strings.TrimSpace(string(data))
		}
	}
	return ""
}

// loadScheduleContext fetches today's calendar events and open tasks and
// returns a Markdown-formatted block for injection into the system prompt.
// Returns an empty string if credentials are missing or any API call fails —
// schedule context is best-effort and must never block startup.
func loadScheduleContext(secretsRoot string) string {
	var parts []string

	events, err := google.ListUpcomingEvents(secretsRoot, 10)
	if err != nil {
		slog.Debug("schedule context: calendar unavailable", "err", err)
	} else if md := google.FormatEventsMarkdown(events); md != "" {
		parts = append(parts, md)
	}

	tasks, err := google.ListTasks(secretsRoot, "@default")
	if err != nil {
		slog.Debug("schedule context: tasks unavailable", "err", err)
	} else if md := google.FormatTasksMarkdown(tasks); md != "" {
		parts = append(parts, md)
	}

	if len(parts) == 0 {
		return ""
	}
	return "## TODAY'S CONTEXT (live)\n" + strings.Join(parts, "\n")
}

// ensureAwarenessFile writes a default AWARENESS.md into
// {storageRoot}/workspace/ if the file does not already exist.
// It is safe to call on every startup - it is a no-op when the file is present.
func ensureAwarenessFile(storageRoot string) {
	awarenessPath := filepath.Join(storageRoot, "workspace", "AWARENESS.md")
	if _, err := os.Stat(awarenessPath); err == nil {
		return // already exists - user may have customised it
	}
	if err := os.MkdirAll(filepath.Dir(awarenessPath), 0o755); err != nil {
		return
	}
	content := buildAwarenessContent(storageRoot)
	_ = os.WriteFile(awarenessPath, []byte(content), 0o644)
}

// buildAwarenessContent returns the default AWARENESS.md content with
// storageRoot substituted in. Kept as a separate function so it can be
// tested without touching the filesystem.
func buildAwarenessContent(storageRoot string) string {
	cronItemsDir := filepath.Join(storageRoot, "workspace", "jobs")
	return "# STRATEGIC AWARENESS\n" +
		"- **Workspace Root:** " + storageRoot + "\n" +
		"- **System Role:** Strategic Orchestrator\n" +
		"- **Edition:** Gobot Strategic Edition\n" +
		"\n" +
		"## SYSTEM STATE\n" +
		"- **Automated Batch System:** Scheduled tasks are modular Markdown files.\n" +
		"- **Task Directory:** `" + cronItemsDir + "`\n" +
		"- **Schema:** Files use YAML front-matter (`id`, `name`, `schedule`, `specialist`, `to`, `enabled`).\n" +
		"- **Trigger:** The scheduler automatically loads these files and converts them into cron jobs.\n" +
		"\n" +
		"## MEMORY & CONTINUITY\n" +
		"- **Daily Journal:** `" + filepath.Join(storageRoot, "workspace", "journal", "YYYY-MM-DD.md") + "`\n" +
		"- **Chronological Continuity:** A rolling journal snippet is automatically injected into your\n" +
		"  context on every turn so you always have the immediate state of play.\n" +
		"- **Long-Term Memory:** Stored in the checkpoint database at\n" +
		"  `" + filepath.Join(storageRoot, "workspace", "checkpoints.db") + "`.\n" +
		"\n" +
		"## OPERATOR MANDATES\n" +
		"- **Zero Drive-Root Writes:** Never write to drive roots. All output goes under `" + storageRoot + "`.\n" +
		"- **Retired Files:** `HISTORY.md` is retired and read-only.\n"
}
