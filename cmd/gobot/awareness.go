package main

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/allthingscode/gobot/internal/memory"
)

const awarenessMaxJournalChars = 4000

// loadSystemPrompt builds the combined system prompt from AWARENESS.md
// (if present) and today's journal continuity block.
// Returns an empty string if neither source has content.
func loadSystemPrompt(storageRoot string) string {
	var parts []string

	awarenessPath := filepath.Join(storageRoot, "workspace", "AWARENESS.md")
	if data, err := os.ReadFile(awarenessPath); err == nil && len(data) > 0 {
		parts = append(parts, strings.TrimSpace(string(data)))
	}

	if continuity := memory.GetJournalContinuity(storageRoot, awarenessMaxJournalChars); continuity != "" {
		parts = append(parts, continuity)
	}

	return strings.Join(parts, "\n\n")
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
