package factory

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const checkpointPrefix = "### CHECKPOINT"

// TimelineEntry represents a single timeline row for factory session history.
type TimelineEntry struct {
	Timestamp  time.Time `json:"timestamp"`
	Specialist string    `json:"specialist,omitempty"`
	EventType  string    `json:"event_type"`
	Notes      string    `json:"notes,omitempty"`
	Source     string    `json:"source,omitempty"`
	Target     string    `json:"target,omitempty"`
}

// TimelineResult is the merged event/checkpoint timeline and parse warning count.
type TimelineResult struct {
	TaskID       string          `json:"task_id"`
	WarningCount int             `json:"warning_count"`
	Entries      []TimelineEntry `json:"entries"`
}

// LoadTimeline reads one task's pipeline log and checkpoints, then returns a merged timeline.
func LoadTimeline(repoRoot, taskID string) (TimelineResult, error) {
	taskDir := filepath.Join(repoRoot, ".private", "session", taskID)
	pipelinePath := filepath.Join(taskDir, "pipeline.log.jsonl")

	pipelineEntries, warningCount, err := loadPipelineEntries(pipelinePath)
	if err != nil {
		return TimelineResult{}, fmt.Errorf("loading pipeline timeline for task %s at %s: %w", taskID, pipelinePath, err)
	}
	if len(pipelineEntries) == 0 {
		return TimelineResult{}, fmt.Errorf("loading pipeline timeline for task %s at %s: no valid events", taskID, pipelinePath)
	}

	checkpointEntries, err := loadCheckpointEntries(taskDir)
	if err != nil {
		return TimelineResult{}, fmt.Errorf("loading checkpoint timeline for task %s: %w", taskID, err)
	}

	entries := append([]TimelineEntry{}, pipelineEntries...)
	entries = append(entries, checkpointEntries...)
	sortTimeline(entries)

	return TimelineResult{
		TaskID:       taskID,
		WarningCount: warningCount,
		Entries:      entries,
	}, nil
}

func loadPipelineEntries(path string) ([]TimelineEntry, int, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, 0, fmt.Errorf("open pipeline log: %w", err)
	}
	defer func() {
		_ = file.Close()
	}()

	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)

	entries := make([]TimelineEntry, 0, 32)
	warnings := 0

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}

		var raw map[string]interface{}
		if err := json.Unmarshal([]byte(line), &raw); err != nil {
			warnings++
			continue
		}

		entry, valid := pipelineEntryFromRaw(raw)
		if !valid {
			warnings++
			continue
		}
		entries = append(entries, entry)
	}
	if err := scanner.Err(); err != nil {
		return nil, warnings, fmt.Errorf("scan pipeline log: %w", err)
	}

	return entries, warnings, nil
}

func pipelineEntryFromRaw(raw map[string]interface{}) (TimelineEntry, bool) {
	eventType := firstNonEmptyString(raw, "event", "type")
	if eventType == "" {
		return TimelineEntry{}, false
	}

	ts, hasTimestamp := parseTimestamp(raw)
	if !hasTimestamp {
		return TimelineEntry{}, false
	}

	return TimelineEntry{
		Timestamp:  ts,
		Specialist: firstNonEmptyString(raw, "specialist"),
		EventType:  eventType,
		Notes:      firstNonEmptyString(raw, "reason", "notes", "summary", "outcome"),
		Source:     firstNonEmptyString(raw, "source_specialist"),
		Target:     firstNonEmptyString(raw, "target_specialist"),
	}, true
}

func parseTimestamp(raw map[string]interface{}) (time.Time, bool) {
	value := firstNonEmptyString(raw, "timestamp", "ts", "time")
	if value == "" {
		return time.Time{}, false
	}

	formats := []string{
		time.RFC3339Nano,
		time.RFC3339,
		"2006-01-02 15:04:05Z07:00",
	}
	for _, layout := range formats {
		if ts, err := time.Parse(layout, value); err == nil {
			return ts.UTC(), true
		}
	}

	return time.Time{}, false
}

func firstNonEmptyString(raw map[string]interface{}, keys ...string) string {
	for _, key := range keys {
		v, ok := raw[key]
		if !ok || v == nil {
			continue
		}
		if s, ok := v.(string); ok {
			s = strings.TrimSpace(s)
			if s != "" {
				return s
			}
			continue
		}
		asText := strings.TrimSpace(fmt.Sprint(v))
		if asText != "" && asText != "<nil>" {
			return asText
		}
	}
	return ""
}

func loadCheckpointEntries(taskDir string) ([]TimelineEntry, error) {
	entries := make([]TimelineEntry, 0, 8)

	roleDirs, err := os.ReadDir(taskDir)
	if err != nil {
		return nil, fmt.Errorf("read task directory: %w", err)
	}

	for _, roleDir := range roleDirs {
		if !roleDir.IsDir() {
			continue
		}
		taskFilePath := filepath.Join(taskDir, roleDir.Name(), "task.md")
		entryGroup, err := checkpointEntriesFromFile(taskFilePath, roleDir.Name())
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return nil, err
		}
		entries = append(entries, entryGroup...)
	}

	return entries, nil
}

func checkpointEntriesFromFile(taskFilePath, specialist string) ([]TimelineEntry, error) {
	file, err := os.Open(taskFilePath)
	if err != nil {
		return nil, fmt.Errorf("open task file: %w", err)
	}
	defer func() {
		_ = file.Close()
	}()

	stat, err := file.Stat()
	if err != nil {
		return nil, fmt.Errorf("stat task file: %w", err)
	}

	checkpoints, err := extractCheckpointNotes(file)
	if err != nil {
		return nil, err
	}
	if len(checkpoints) == 0 {
		return nil, nil
	}

	entries := make([]TimelineEntry, 0, len(checkpoints))
	for _, cp := range checkpoints {
		entries = append(entries, TimelineEntry{
			Timestamp:  stat.ModTime().UTC(),
			Specialist: specialist,
			EventType:  "checkpoint",
			Notes:      cp,
		})
	}

	return entries, nil
}

func extractCheckpointNotes(reader io.Reader) ([]string, error) {
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 0, 16*1024), 1024*1024)

	notes := make([]string, 0, 4)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if !strings.HasPrefix(line, checkpointPrefix) {
			continue
		}
		note := strings.TrimSpace(strings.TrimPrefix(line, checkpointPrefix))
		if note == "" {
			note = "(no summary)"
		}
		notes = append(notes, note)
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("scan checkpoint headings: %w", err)
	}
	return notes, nil
}

func sortTimeline(entries []TimelineEntry) {
	sort.SliceStable(entries, func(i, j int) bool {
		if !entries[i].Timestamp.Equal(entries[j].Timestamp) {
			return entries[i].Timestamp.Before(entries[j].Timestamp)
		}
		if entries[i].Specialist != entries[j].Specialist {
			return entries[i].Specialist < entries[j].Specialist
		}
		if entries[i].EventType != entries[j].EventType {
			return entries[i].EventType < entries[j].EventType
		}
		return entries[i].Notes < entries[j].Notes
	})
}
