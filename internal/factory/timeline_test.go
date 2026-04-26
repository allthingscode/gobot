//nolint:testpackage // validates unexported timeline helpers directly
package factory

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const (
	taskID         = "C-185"
	roleArchitect  = "architect"
	roleReviewer   = "reviewer"
	checkpointNote = "Implementation done"
)

func TestLoadTimelineHappyPath(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	pipelinePath := filepath.Join(root, ".private", "session", taskID, "pipeline.log.jsonl")
	writeFile(
		t,
		pipelinePath,
		`{"event":"session_start","timestamp":"2026-04-26T10:00:00Z","specialist":"architect","notes":"start"}`+"\n"+
			`{"event":"handoff","timestamp":"2026-04-26T10:10:00Z","source_specialist":"architect","target_specialist":"reviewer","reason":"ready"}`,
	)
	taskFile := filepath.Join(root, ".private", "session", taskID, roleArchitect, "task.md")
	writeFile(t, taskFile, "# Notes\n### CHECKPOINT "+checkpointNote+"\n")
	ts := time.Date(2026, 4, 26, 10, 30, 0, 0, time.UTC)
	if err := os.Chtimes(taskFile, ts, ts); err != nil {
		t.Fatalf("setting checkpoint file timestamp: %v", err)
	}

	got, err := LoadTimeline(root, taskID)
	if err != nil {
		t.Fatalf("LoadTimeline returned error: %v", err)
	}
	if got.WarningCount != 0 {
		t.Fatalf("warning count = %d, want 0", got.WarningCount)
	}
	if len(got.Entries) != 3 {
		t.Fatalf("entry count = %d, want 3", len(got.Entries))
	}
	assertContainsCheckpoint(t, got.Entries, checkpointNote)
	assertContainsHandoff(t, got.Entries, roleArchitect, roleReviewer)
}

func TestLoadTimelineMalformedLineWarning(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	writeFile(
		t,
		filepath.Join(root, ".private", "session", taskID, "pipeline.log.jsonl"),
		`{"event":"session_start","timestamp":"2026-04-26T10:00:00Z","specialist":"architect"}`+"\n"+`{this is not valid json}`,
	)

	got, err := LoadTimeline(root, taskID)
	if err != nil {
		t.Fatalf("LoadTimeline returned error: %v", err)
	}
	if got.WarningCount != 1 {
		t.Fatalf("warning count = %d, want 1", got.WarningCount)
	}
	if len(got.Entries) != 1 {
		t.Fatalf("entry count = %d, want 1", len(got.Entries))
	}
}

func TestLoadTimelineMissingPipeline(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	_, err := LoadTimeline(root, taskID)
	if err == nil {
		t.Fatal("expected error for missing pipeline")
	}
	if !strings.Contains(err.Error(), "task C-185") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestLoadTimelineNoValidEvents(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	writeFile(t, filepath.Join(root, ".private", "session", taskID, "pipeline.log.jsonl"), "{invalid}\n")

	_, err := LoadTimeline(root, taskID)
	if err == nil {
		t.Fatal("expected error for invalid events")
	}
	if !strings.Contains(err.Error(), "no valid events") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestExtractCheckpointNotes(t *testing.T) {
	t.Parallel()

	text := "# Task\n### CHECKPOINT Phase 1 complete\n## Other\n### CHECKPOINT\n"
	got, err := extractCheckpointNotes(strings.NewReader(text))
	if err != nil {
		t.Fatalf("extractCheckpointNotes returned error: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("notes length = %d, want 2", len(got))
	}
	if got[0] != "Phase 1 complete" {
		t.Fatalf("first note = %q, want %q", got[0], "Phase 1 complete")
	}
	if got[1] != "(no summary)" {
		t.Fatalf("second note = %q, want %q", got[1], "(no summary)")
	}
}

func TestPipelineEntryFromRaw_FallbackFields(t *testing.T) {
	t.Parallel()

	raw := map[string]interface{}{
		"type":              "handoff",
		"time":              "2026-04-26 10:15:00+00:00",
		"reason":            "handoff ready",
		"source_specialist": roleArchitect,
		"target_specialist": roleReviewer,
	}

	entry, ok := pipelineEntryFromRaw(raw)
	if !ok {
		t.Fatal("expected entry to be valid")
	}
	if entry.EventType != "handoff" {
		t.Fatalf("event_type = %q, want %q", entry.EventType, "handoff")
	}
	if entry.Source != roleArchitect || entry.Target != roleReviewer {
		t.Fatalf("unexpected handoff edge: %s -> %s", entry.Source, entry.Target)
	}
}

func TestPipelineEntryFromRaw_Invalid(t *testing.T) {
	t.Parallel()

	if _, ok := pipelineEntryFromRaw(map[string]interface{}{"event": "session_start"}); ok {
		t.Fatal("expected invalid entry when timestamp is missing")
	}
	if _, ok := pipelineEntryFromRaw(map[string]interface{}{"timestamp": "2026-04-26T10:00:00Z"}); ok {
		t.Fatal("expected invalid entry when event is missing")
	}
}

func TestSortTimeline(t *testing.T) {
	t.Parallel()

	base := time.Date(2026, 4, 26, 10, 0, 0, 0, time.UTC)
	entries := []TimelineEntry{
		{Timestamp: base, Specialist: roleReviewer, EventType: "handoff", Notes: "b"},
		{Timestamp: base, Specialist: roleArchitect, EventType: "session_end", Notes: "c"},
		{Timestamp: base.Add(-time.Minute), Specialist: roleArchitect, EventType: "session_start", Notes: "a"},
	}
	sortTimeline(entries)
	if entries[0].EventType != "session_start" {
		t.Fatalf("first entry = %q, want session_start", entries[0].EventType)
	}
	if entries[1].Specialist != roleArchitect {
		t.Fatalf("second specialist = %q, want architect", entries[1].Specialist)
	}
	if entries[2].Specialist != roleReviewer {
		t.Fatalf("third specialist = %q, want reviewer", entries[2].Specialist)
	}
}

func assertContainsCheckpoint(t *testing.T, entries []TimelineEntry, note string) {
	t.Helper()
	for _, entry := range entries {
		if entry.EventType == "checkpoint" && strings.Contains(entry.Notes, note) {
			return
		}
	}
	t.Fatalf("expected checkpoint containing %q not found", note)
}

func assertContainsHandoff(t *testing.T, entries []TimelineEntry, source, target string) {
	t.Helper()
	for _, entry := range entries {
		if entry.EventType == "handoff" && entry.Source == source && entry.Target == target {
			return
		}
	}
	t.Fatalf("expected handoff %s -> %s not found", source, target)
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("creating parent dir: %v", err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("writing file %s: %v", path, err)
	}
}
