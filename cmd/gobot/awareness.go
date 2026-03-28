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
