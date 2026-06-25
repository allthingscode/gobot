//nolint:testpackage // requires unexported manager internals (newTestManager, consts) for testing
package context

import (
	"context"
	"database/sql"
	"testing"
)

func retMsg(text string) StrategicMessage {
	content := MessageContent{Str: strPtr(text)}
	return StrategicMessage{Role: RoleUser, Content: &content}
}

func countCheckpoints(t *testing.T, m *CheckpointManager, threadID string) int {
	t.Helper()
	var n int
	if err := m.db.QueryRowContext(
		context.Background(),
		`SELECT COUNT(*) FROM checkpoints WHERE thread_id = ?`, threadID,
	).Scan(&n); err != nil {
		t.Fatalf("count checkpoints: %v", err)
	}
	return n
}

func freelistCount(t *testing.T, db *sql.DB) int {
	t.Helper()
	var n int
	if err := db.QueryRowContext(context.Background(), "PRAGMA freelist_count").Scan(&n); err != nil {
		t.Fatalf("read freelist_count: %v", err)
	}
	return n
}

// seedFreelistBloat inserts many wide rows and deletes them, leaving a large
// freelist - mimicking the dead pages a pre-C-335 database accumulated before
// checkpoint pruning would have freed them.
func seedFreelistBloat(t *testing.T, db *sql.DB) {
	t.Helper()
	wide := make([]byte, 64*1024)
	for i := range wide {
		wide[i] = 'x'
	}
	for i := 0; i < 200; i++ {
		if _, err := db.ExecContext(context.Background(),
			`INSERT INTO checkpoints (thread_id, iteration, state) VALUES (?, ?, ?)`,
			"bloat", i, string(wide)); err != nil {
			t.Fatalf("seed insert %d: %v", i, err)
		}
	}
	if _, err := db.ExecContext(context.Background(),
		`DELETE FROM checkpoints WHERE thread_id = ?`, "bloat"); err != nil {
		t.Fatalf("seed delete: %v", err)
	}
}

// AC1 + AC2: row count per thread is capped at maxCheckpointsPerThread after many
// saves, and LoadLatest still returns the most recent iteration intact.
func TestSaveSnapshot_BoundsRetention(t *testing.T) {
	t.Parallel()

	m := newTestManager(t)
	const threadID = "t-bound"
	if err := m.CreateThread(context.Background(), threadID, "model", nil); err != nil {
		t.Fatalf("CreateThread: %v", err)
	}

	const iterations = 50
	for i := 1; i <= iterations; i++ {
		if _, err := m.SaveSnapshot(context.Background(), threadID, i, []StrategicMessage{retMsg("m")}); err != nil {
			t.Fatalf("SaveSnapshot iter %d: %v", i, err)
		}
	}

	if got := countCheckpoints(t, m, threadID); got != maxCheckpointsPerThread {
		t.Errorf("checkpoint row count = %d, want %d", got, maxCheckpointsPerThread)
	}

	snap, err := m.LoadLatest(context.Background(), threadID)
	if err != nil {
		t.Fatalf("LoadLatest: %v", err)
	}
	if snap == nil {
		t.Fatal("LoadLatest returned nil after pruning")
	}
	if snap.Iteration != iterations {
		t.Errorf("LoadLatest iteration = %d, want %d (prune must never delete the newest row)", snap.Iteration, iterations)
	}
	if len(snap.Messages) != 1 {
		t.Errorf("LoadLatest messages = %d, want 1", len(snap.Messages))
	}
}

// AC3: pruning is scoped per thread - saves on one thread never delete another's rows.
func TestSaveSnapshot_PruneScopedPerThread(t *testing.T) {
	t.Parallel()

	m := newTestManager(t)
	for _, id := range []string{"a", "b"} {
		if err := m.CreateThread(context.Background(), id, "model", nil); err != nil {
			t.Fatalf("CreateThread %s: %v", id, err)
		}
	}

	// Thread "a" gets a handful of saves (under the cap); "b" overruns the cap.
	for i := 1; i <= 3; i++ {
		if _, err := m.SaveSnapshot(context.Background(), "a", i, []StrategicMessage{retMsg("a")}); err != nil {
			t.Fatalf("SaveSnapshot a iter %d: %v", i, err)
		}
	}
	for i := 1; i <= maxCheckpointsPerThread+15; i++ {
		if _, err := m.SaveSnapshot(context.Background(), "b", i, []StrategicMessage{retMsg("b")}); err != nil {
			t.Fatalf("SaveSnapshot b iter %d: %v", i, err)
		}
	}

	if got := countCheckpoints(t, m, "a"); got != 3 {
		t.Errorf("thread a row count = %d, want 3 (under cap, untouched by b's saves)", got)
	}
	if got := countCheckpoints(t, m, "b"); got != maxCheckpointsPerThread {
		t.Errorf("thread b row count = %d, want %d", got, maxCheckpointsPerThread)
	}
}

// AC5: a freshly created (small-freelist) database opens without running VACUUM and
// stays usable. reclaimIfBloated runs on the open path inside GetCheckpointManager,
// so a successful save here exercises it returning early under the threshold.
func TestReclaimIfBloated_SkipsWhenSmall(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	db, err := openDB(root)
	if err != nil {
		t.Fatalf("openDB: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if err := initSchema(db); err != nil {
		t.Fatalf("initSchema: %v", err)
	}

	if freelist := freelistCount(t, db); freelist > vacuumFreelistThreshold {
		t.Fatalf("fresh DB freelist = %d, expected <= %d", freelist, vacuumFreelistThreshold)
	}
	if err := reclaimIfBloated(db); err != nil {
		t.Fatalf("reclaimIfBloated on fresh DB: %v", err)
	}

	// DB remains usable after the (no-op) reclaim.
	m := &CheckpointManager{db: db}
	if err := m.CreateThread(context.Background(), "t", "model", nil); err != nil {
		t.Fatalf("CreateThread after reclaim: %v", err)
	}
	if _, err := m.SaveSnapshot(context.Background(), "t", 1, []StrategicMessage{retMsg("x")}); err != nil {
		t.Fatalf("SaveSnapshot after reclaim: %v", err)
	}
}

// reclaimIfBloated actually VACUUMs and reclaims space once the freelist exceeds the
// threshold (simulating a pre-C-335 database's accumulated dead pages).
func TestReclaimIfBloated_VacuumsWhenBloated(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	db, err := openDB(root)
	if err != nil {
		t.Fatalf("openDB: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if err := initSchema(db); err != nil {
		t.Fatalf("initSchema: %v", err)
	}

	seedFreelistBloat(t, db)

	before := freelistCount(t, db)
	if before <= vacuumFreelistThreshold {
		t.Skipf("seeded freelist %d did not exceed threshold %d; environment page size differs", before, vacuumFreelistThreshold)
	}

	if err := reclaimIfBloated(db); err != nil {
		t.Fatalf("reclaimIfBloated: %v", err)
	}

	if after := freelistCount(t, db); after >= before {
		t.Errorf("freelist after VACUUM = %d, want < %d", after, before)
	}
}
