//nolint:testpackage // exercises unexported scheduler poll/save internals
package cron

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

const testIndexJobID = "index_workspace"

// assertNoTempResidue fails if any temp file from the atomic write helper
// (os.CreateTemp(dir, ".tmp_")) was left behind in dir. A leftover temp file
// means the write did not complete its rename+cleanup cycle.
func assertNoTempResidue(t *testing.T, dir string) {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("read store dir: %v", err)
	}
	for _, e := range entries {
		if name := e.Name(); len(name) >= 5 && name[:5] == ".tmp_" {
			t.Errorf("leftover atomic-write temp file in %s: %s", dir, name)
		}
	}
}

// assertDecodableStore fails unless storePath holds a complete, valid jobs.json
// that round-trips back into a Store. A truncated/partial write would fail here.
func assertDecodableStore(t *testing.T, storePath string) Store {
	t.Helper()
	data, err := os.ReadFile(storePath)
	if err != nil {
		t.Fatalf("read store: %v", err)
	}
	var store Store
	if err := json.Unmarshal(data, &store); err != nil {
		t.Fatalf("store is not valid JSON (partial write?): %v", err)
	}
	return store
}

// B-004 regression: SeedJob must persist jobs.json atomically (temp file +
// rename) so a crash mid-write can never truncate the store. We assert the
// resulting file is fully decodable and no temp residue is left behind.
func TestSeedJob_WritesAtomically(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	storePath := filepath.Join(dir, "jobs.json")

	if _, err := SeedJob(storePath, EveryJob(testIndexJobID, "name", "[SYSTEM] INDEX_WORKSPACE", 1000)); err != nil {
		t.Fatalf("SeedJob: %v", err)
	}

	store := assertDecodableStore(t, storePath)
	if len(store.Jobs) != 1 || store.Jobs[0].ID != testIndexJobID {
		t.Fatalf("unexpected store after atomic seed: %+v", store.Jobs)
	}
	assertNoTempResidue(t, dir)
}

// B-004 regression: SeedJob creates the parent directory when absent. This
// previously relied on an explicit os.MkdirAll; it now must be handled by the
// atomic write helper. A nested path that does not yet exist must still succeed.
func TestSeedJob_CreatesParentDirAtomically(t *testing.T) {
	t.Parallel()
	dir := filepath.Join(t.TempDir(), "nested", "deeper")
	storePath := filepath.Join(dir, "jobs.json")

	seeded, err := SeedJob(storePath, EveryJob(testIndexJobID, "name", "[SYSTEM] INDEX_WORKSPACE", 1000))
	if err != nil {
		t.Fatalf("SeedJob into nonexistent dir: %v", err)
	}
	if !seeded {
		t.Fatal("expected seeded=true")
	}
	assertDecodableStore(t, storePath)
	assertNoTempResidue(t, dir)
}

// B-004 regression: the scheduler's own persistence (saveStore, reached via
// poll when job state changes) must also be atomic. We drive a due job through
// a poll so saveStore runs, then assert the store is intact with no temp
// residue.
func TestSchedulerSaveStore_WritesAtomically(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	storePath := filepath.Join(dir, "jobs.json")
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

	// Init poll establishes NextRunAtMS and persists via saveStore.
	if err := s.poll(ctx); err != nil {
		t.Fatalf("init poll: %v", err)
	}
	// Advance past the interval and poll again so the job dispatches and the
	// scheduler saves the updated success/next-run state.
	fc.Advance(time.Duration(intervalMS+1) * time.Millisecond)
	if err := s.poll(ctx); err != nil {
		t.Fatalf("second poll: %v", err)
	}

	store := assertDecodableStore(t, storePath)
	if len(store.Jobs) != 1 || store.Jobs[0].State.SuccessCount != 1 {
		t.Fatalf("expected persisted success state, got: %+v", store.Jobs)
	}
	assertNoTempResidue(t, dir)
}
