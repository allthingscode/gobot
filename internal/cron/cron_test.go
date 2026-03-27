package cron

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestShouldReload(t *testing.T) {
	tests := []struct {
		name         string
		currentMtime int64
		lastMtime    int64
		currentSize  int64
		lastSize     int64
		want         bool
	}{
		{"no change", 100, 100, 50, 50, false},
		{"mtime change", 101, 100, 50, 50, true},
		{"size change", 100, 100, 51, 50, true},
		{"both change", 101, 100, 51, 50, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := ShouldReload(tt.currentMtime, tt.lastMtime, tt.currentSize, tt.lastSize); got != tt.want {
				t.Errorf("ShouldReload() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestResolveRoutableChannel(t *testing.T) {
	tests := []struct {
		name        string
		payload     Payload
		wantChannel string
		wantTo      string
		wantSilent  bool
	}{
		{
			name: "silent message",
			payload: Payload{
				Message: "hello [SILENT] world",
				Channel: "telegram",
			},
			wantChannel: "",
			wantTo:      "",
			wantSilent:  true,
		},
		{
			name: "routable telegram",
			payload: Payload{
				Message: "hello",
				Channel: "telegram",
				To:      "123",
			},
			wantChannel: "telegram",
			wantTo:      "123",
			wantSilent:  false,
		},
		{
			name: "unroutable cli",
			payload: Payload{
				Message: "hello",
				Channel: "cli",
			},
			wantChannel: "telegram", // fallback mandate
			wantTo:      "",
			wantSilent:  false,
		},
		{
			name: "missing channel",
			payload: Payload{
				Message: "hello",
				Channel: "",
			},
			wantChannel: "telegram", // fallback mandate
			wantTo:      "",
			wantSilent:  false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotChannel, gotTo, gotSilent := ResolveRoutableChannel(tt.payload, "D:/storage")
			if gotChannel != tt.wantChannel || gotTo != tt.wantTo || gotSilent != tt.wantSilent {
				t.Errorf("ResolveRoutableChannel() = (%v, %v, %v), want (%v, %v, %v)",
					gotChannel, gotTo, gotSilent, tt.wantChannel, tt.wantTo, tt.wantSilent)
			}
		})
	}
}

func TestDetectModularChange(t *testing.T) {
	tmpDir := t.TempDir()

	// 1. Initial detection (empty dir)
	changed, _ := DetectModularChange(tmpDir, 0.0)
	if changed {
		t.Errorf("expected no change for empty dir")
	}

	// 2. Add a file
	f1 := filepath.Join(tmpDir, "job1.md")
	if err := os.WriteFile(f1, []byte("test"), 0644); err != nil {
		t.Fatal(err)
	}

	changed, newMtime := DetectModularChange(tmpDir, 0.0)
	if !changed {
		t.Errorf("expected change after adding file")
	}
	if newMtime <= 0 {
		t.Errorf("expected positive mtime")
	}

	// 3. Detect with current mtime (no change)
	changed, sameMtime := DetectModularChange(tmpDir, newMtime)
	if changed {
		t.Errorf("expected no change when mtime matches")
	}
	if sameMtime != newMtime {
		t.Errorf("mtime should match")
	}

	// 4. Modify file (force mtime change)
	if err := os.Chtimes(f1, time.Now().Add(time.Hour), time.Now().Add(time.Hour)); err != nil {
		t.Fatal(err)
	}

	changed, newerMtime := DetectModularChange(tmpDir, newMtime)
	if !changed {
		t.Errorf("expected change after modifying file")
	}
	if newerMtime == newMtime {
		t.Errorf("expected different mtime")
	}
}

func TestMergeModularJobs(t *testing.T) {
	stateCache := map[string]JobState{
		"job1": {RunCount: 5},
	}

	storeJobs := []Job{
		{ID: "existing1", Name: "Existing 1"},
	}

	modularJobs := []Job{
		{ID: "job1", Name: "Job 1", Schedule: Schedule{Kind: KindEvery}},
		{ID: "existing1", Name: "Updated Name"}, // should update existing
	}

	merged := MergeModularJobs(storeJobs, modularJobs, stateCache)

	if len(merged) != 2 {
		t.Errorf("expected 2 jobs after merge, got %d", len(merged))
	}

	// Check if state was restored
	for _, j := range merged {
		if j.ID == "job1" && j.State.RunCount != 5 {
			t.Errorf("expected job1 state to be restored")
		}
		if j.ID == "existing1" && j.Name != "Updated Name" {
			t.Errorf("expected existing1 name to be updated")
		}
	}
}
