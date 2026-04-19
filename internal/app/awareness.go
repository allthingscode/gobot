package app

import (
	"context"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/integrations/google"
	"github.com/allthingscode/gobot/internal/memory"
	"golang.org/x/sync/errgroup"
)

const awarenessMaxJournalChars = 4000

// userHomeDir is a package-level variable to allow mocking in tests.
//
//nolint:gochecknoglobals // Hook for testability (F-133 hardening)
var userHomeDir = os.UserHomeDir

// LoadSystemPrompt builds the combined system prompt from:
//  1. .private/SOUL.md     — behavior rules (how to respond)
//  2. .private/IDENTITY.md — who Matthew is (personal context)
//  3. AWARENESS.md         — how this system works (paths, cron, journal)
//  4. Journal continuity   — recent activity (auto-injected)
//  5. Live schedule        — today's calendar + tasks (best-effort)
func LoadSystemPrompt(cfg *config.Config) string {
	var parts []string

	for _, name := range []string{"SOUL.md", "IDENTITY.md"} {
		if data := loadPrivateFile(cfg, name); data != "" {
			parts = append(parts, data)
		}
	}

	awarenessPath := cfg.WorkspacePath("", "AWARENESS.md")
	if data, err := os.ReadFile(awarenessPath); err == nil && len(data) > 0 {
		parts = append(parts, strings.TrimSpace(string(data)))
	}

	if continuity := memory.GetJournalContinuity(cfg.StorageRoot(), awarenessMaxJournalChars); continuity != "" {
		parts = append(parts, continuity)
	}

	secretsRoot := cfg.SecretsRoot()
	if schedule := loadScheduleContext(secretsRoot); schedule != "" {
		parts = append(parts, schedule)
	}

	return strings.Join(parts, "\n\n")
}

// loadPrivateFile reads a file from ~/.gobot/ (canonical user config), or
// {storageRoot}/workspace/ (production fallback). Returns empty string if not found.
func loadPrivateFile(cfg *config.Config, filename string) string {
	var candidates []string

	// Primary: ~/.gobot/{filename} — canonical user config dir (next to config.json)
	if home, err := userHomeDir(); err == nil {
		candidates = append(candidates, filepath.Join(home, ".gobot", filename))
	}

	// Fallback: {storage_root}/workspace/{filename} — workspace override
	candidates = append(candidates, cfg.WorkspacePath("", filename))

	for _, p := range candidates {
		if data, err := os.ReadFile(p); err == nil && len(data) > 0 {
			return strings.TrimSpace(string(data))
		}
	}
	return ""
}

// loadScheduleContext fetches today's calendar events and open tasks and
// returns a Markdown block for injection into the system prompt.
// Best-effort — never blocks startup on failure.
func loadScheduleContext(secretsRoot string) string {
	if secretsRoot == "" {
		return ""
	}

	// Turn-time schedule loading must be extremely fast and responsive to context.
	// We use a 5s hard cap to ensure turn start is not delayed indefinitely.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	g, gctx := errgroup.WithContext(ctx)
	var calendarMD, tasksMD string

	g.Go(func() error {
		events, err := google.ListUpcomingEvents(gctx, secretsRoot, 10)
		if err != nil {
			slog.Debug("schedule context: calendar unavailable", "err", err)
			return nil
		}
		calendarMD = google.FormatEventsMarkdown(events)
		return nil
	})

	g.Go(func() error {
		tasks, err := google.ListTasks(gctx, secretsRoot, "@default")
		if err != nil {
			slog.Debug("schedule context: tasks unavailable", "err", err)
			return nil
		}
		tasksMD = google.FormatTasksMarkdown(tasks)
		return nil
	})

	// We ignore errgroup errors because tasks are best-effort.
	_ = g.Wait()

	var parts []string
	if calendarMD != "" {
		parts = append(parts, calendarMD)
	}
	if tasksMD != "" {
		parts = append(parts, tasksMD)
	}

	if len(parts) == 0 {
		return ""
	}
	return "## TODAY'S CONTEXT (live)\n" + strings.Join(parts, "\n")
}

// EnsureAwarenessFile writes a default AWARENESS.md into
// {storageRoot}/workspace/ if the file does not already exist.
// Safe to call on every startup — no-op when the file is present.
func EnsureAwarenessFile(cfg *config.Config) {
	awarenessPath := cfg.WorkspacePath("", "AWARENESS.md")
	if _, err := os.Stat(awarenessPath); err == nil {
		return
	}
	if err := os.MkdirAll(filepath.Dir(awarenessPath), 0o755); err != nil {
		return
	}
	_ = os.WriteFile(awarenessPath, []byte(buildAwarenessContent(cfg)), 0o600)
}

// buildAwarenessContent returns the default AWARENESS.md content.
// Kept separate so it can be tested without filesystem side effects.
func buildAwarenessContent(cfg *config.Config) string {
	storageRoot := cfg.StorageRoot()
	cronItemsDir := cfg.WorkspacePath("", "jobs")
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
		"- **Daily Journal:** `" + cfg.WorkspacePath("", "journal", "YYYY-MM-DD.md") + "`\n" +
		"- **Chronological Continuity:** A rolling journal snippet is injected into context on every turn.\n" +
		"- **Long-Term Memory:** Checkpoint database at `" + cfg.WorkspacePath("", "checkpoints.db") + "`.\n" +
		"\n" +
		"## OPERATOR MANDATES\n" +
		"- **Zero Drive-Root Writes:** Never write to drive roots. All output goes under `" + storageRoot + "`.\n"
}
