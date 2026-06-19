//nolint:testpackage // exercises unexported scheduler poll/clock internals
package cron

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestSeedJob_CreatesStoreWhenAbsent(t *testing.T) {
	t.Parallel()
	storePath := filepath.Join(t.TempDir(), "nested", "jobs.json")
	job := EveryJob(testIndexJobID, "Automatic Workspace Vector Index", "[SYSTEM] INDEX_WORKSPACE", 1000)

	seeded, err := SeedJob(storePath, job)
	if err != nil {
		t.Fatalf("SeedJob: %v", err)
	}
	if !seeded {
		t.Fatal("expected seeded=true on first call")
	}

	data, err := os.ReadFile(storePath)
	if err != nil {
		t.Fatalf("read store: %v", err)
	}
	var store Store
	if err := json.Unmarshal(data, &store); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(store.Jobs) != 1 || store.Jobs[0].ID != testIndexJobID {
		t.Fatalf("unexpected store: %+v", store.Jobs)
	}
}

func TestSeedJob_IdempotentOnExistingID(t *testing.T) {
	t.Parallel()
	storePath := filepath.Join(t.TempDir(), "jobs.json")
	job := EveryJob(testIndexJobID, "name", "[SYSTEM] INDEX_WORKSPACE", 1000)

	if _, err := SeedJob(storePath, job); err != nil {
		t.Fatalf("first seed: %v", err)
	}
	seeded, err := SeedJob(storePath, job)
	if err != nil {
		t.Fatalf("second seed: %v", err)
	}
	if seeded {
		t.Error("expected seeded=false when job already present")
	}
}

// End-to-end: an automatically seeded index_workspace job drives the scheduler
// to dispatch the INDEX_WORKSPACE payload on its interval, with no operator
// jobs.json editing (F-142 acceptance: automatic indexing without manual setup).
func TestSeededIndexJob_DispatchesOnInterval(t *testing.T) {
	t.Parallel()
	storePath := filepath.Join(t.TempDir(), "jobs.json")
	const intervalMS = int64(60 * 1000)

	if _, err := SeedJob(storePath, EveryJob(
		testIndexJobID, "Automatic Workspace Vector Index", "[SYSTEM] INDEX_WORKSPACE", intervalMS,
	)); err != nil {
		t.Fatalf("seed: %v", err)
	}

	dispatcher := &mockDispatcher{}
	fc := NewFakeClock(time.UnixMilli(1000))
	s := NewScheduler(storePath, "", dispatcher).WithClock(fc)
	ctx := context.Background()

	// First poll initializes NextRunAtMS (interval-based "every" schedules do
	// not fire on the init poll).
	if err := s.poll(ctx); err != nil {
		t.Fatalf("init poll: %v", err)
	}
	if len(dispatcher.payloads) != 0 {
		t.Fatalf("job must not fire on init poll, got %d", len(dispatcher.payloads))
	}

	// Advance past the interval and poll again — the job must now dispatch.
	fc.Advance(time.Duration(intervalMS+1) * time.Millisecond)
	if err := s.poll(ctx); err != nil {
		t.Fatalf("second poll: %v", err)
	}

	if len(dispatcher.payloads) != 1 {
		t.Fatalf("expected 1 dispatch, got %d", len(dispatcher.payloads))
	}
	if got := dispatcher.payloads[0].Message; got != "[SYSTEM] INDEX_WORKSPACE" {
		t.Errorf("payload message = %q, want [SYSTEM] INDEX_WORKSPACE", got)
	}
	if got := dispatcher.payloads[0].ID; got != testIndexJobID {
		t.Errorf("payload id = %q, want index_workspace", got)
	}
}
