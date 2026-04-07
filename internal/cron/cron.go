// Package cron provides scheduling and execution of background agent tasks.
package cron

import (
	"encoding/json"
	"os"
	"strings"
)

// ScheduleKind defines the type of schedule (at, every, cron).
type ScheduleKind string

const (
	KindAt    ScheduleKind = "at"
	KindEvery ScheduleKind = "every"
	KindCron  ScheduleKind = "cron"
)

// Schedule defines when a job should run.
type Schedule struct {
	Kind    ScheduleKind `json:"kind"`
	AtMS    *int64       `json:"atMs,omitempty"`    // for "at"
	EveryMS *int64       `json:"everyMs,omitempty"` // for "every"
	Expr    string       `json:"expr,omitempty"`    // for "cron"
	TZ      string       `json:"tz,omitempty"`      // for "cron"
}

// Payload defines the message to be sent when a job triggers.
type Payload struct {
	ID      string `json:"id,omitempty"`
	Channel string `json:"channel"`
	To      string `json:"to,omitempty"`
	Subject string `json:"subject,omitempty"`
	Message string `json:"message"`
}

// JobState tracks the execution history of a job.
type JobState struct {
	LastRunAtMS  int64 `json:"lastRunAtMs"`
	NextRunAtMS  int64 `json:"nextRunAtMs"`
	RunCount     int   `json:"runCount"`
	SuccessCount int   `json:"successCount"`
	FailureCount int   `json:"failureCount"`
}

// Job represents a single scheduled task.
type Job struct {
	ID       string   `json:"id"`
	Name     string   `json:"name"`
	Enabled  bool     `json:"enabled"`
	Schedule Schedule `json:"schedule"`
	Payload  Payload  `json:"payload"`
	State    JobState `json:"state"`
}

// Store represents the persistent JSON structure in jobs.json.
type Store struct {
	Jobs []Job `json:"jobs"`
}

// EncodeJSON marshals the Store into JSON bytes.
func (s *Store) EncodeJSON() ([]byte, error) {
	return json.MarshalIndent(s, "", "    ")
}

// DecodeJSON unmarshals JSON bytes into the Store.
func (s *Store) DecodeJSON(data []byte) error {
	return json.Unmarshal(data, s)
}

// ── Logic Ported from cron_logic.py ──────────────────────────────────────────

// ShouldReload returns true if the store file has changed on disk.
func ShouldReload(currentMtime int64, lastMtime int64, currentSize int64, lastSize int64) bool {
	return currentMtime != lastMtime || currentSize != lastSize
}

// ResolveRoutableChannel implements the [SILENT] and unroutable channel logic.
// Ported from resolve_routable_channel in cron_logic.py.
func ResolveRoutableChannel(p Payload, _ string) (channel string, to string, silent bool) {
	if strings.Contains(p.Message, "[SILENT]") {
		return "", "", true
	}

	// For Phase 3, we default unroutable/missing channels to "telegram"
	// as per the Python implementation's fallback logic.
	channel = p.Channel
	to = p.To

	if channel == "" || channel == "cli" {
		// In a full implementation, we would call strategic_resolve_job_channel here.
		// For now, we follow the fallback mandate: default to "telegram".
		return "telegram", "", false
	}

	return channel, to, false
}

// DetectModularChange detects if any modular .md job files have changed.
// Ported from detect_modular_change in cron_logic.py.
func DetectModularChange(itemsDir string, lastItemsMtime float64) (changed bool, newMtime float64) {
	files, err := os.ReadDir(itemsDir)
	if err != nil {
		return false, 0.0
	}

	var totalMtime float64
	found := false
	for _, f := range files {
		if !f.IsDir() && strings.HasSuffix(strings.ToLower(f.Name()), ".md") {
			info, err := f.Info()
			if err == nil {
				totalMtime += float64(info.ModTime().UnixNano()) / 1e9
				found = true
			}
		}
	}

	if !found {
		return false, 0.0
	}

	if totalMtime != lastItemsMtime {
		return true, totalMtime
	}

	return false, lastItemsMtime
}

// MergeModularJobs merges modular jobs into the store, preserving state.
func MergeModularJobs(storeJobs []Job, modularJobs []Job, stateCache map[string]JobState) []Job {
	for i, mj := range modularJobs {
		if state, ok := stateCache[mj.ID]; ok {
			modularJobs[i].State = state
		}

		found := false
		for j, existing := range storeJobs {
			if existing.ID == mj.ID {
				storeJobs[j].Schedule = mj.Schedule
				storeJobs[j].Payload = mj.Payload
				storeJobs[j].Name = mj.Name
				found = true
				break
			}
		}

		if !found {
			storeJobs = append(storeJobs, modularJobs[i])
		}
	}
	return storeJobs
}
