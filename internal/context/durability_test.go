//nolint:testpackage // requires unexported checkpoint internals for testing
package context

import (
	"context"
	"sync"
	"testing"
)

// TestCheckpointManager_CrashAndRecover simulates a process restart by:
// 1. Opening a DB, saving state, then closing it (simulating a crash).
// 2. Reopening the same DB path and verifying the state is fully intact.
// This is the core F-018 durability guarantee.
//
//nolint:cyclop // test complexity justified by crash/recover scenarios
func TestCheckpointManager_CrashAndRecover(t *testing.T) {
	t.Parallel()
	root := t.TempDir()

	// ── Phase 1: save state, then close the DB ────────────────────────────────
	db1, err := openDB(root)
	if err != nil {
		t.Fatalf("phase1 openDB: %v", err)
	}
	if err := initSchema(db1); err != nil {
		_ = db1.Close()
		t.Fatalf("phase1 initSchema: %v", err)
	}
	m1 := &CheckpointManager{db: db1}

	if err := m1.CreateThread(context.Background(), "t1", "gemini-2.5-flash", map[string]any{"key": "value"}); err != nil {
		t.Fatalf("phase1 CreateThread: %v", err)
	}
	msgs := []StrategicMessage{
		{Role: RoleUser, Content: &MessageContent{Str: strPtr("hello")}},
		{Role: RoleAssistant, Content: &MessageContent{Str: strPtr("world")}},
	}
	ok, err := m1.SaveSnapshot(context.Background(), "t1", 1, msgs)
	if err != nil || !ok {
		t.Fatalf("phase1 SaveSnapshot: ok=%v err=%v", ok, err)
	}
	_ = db1.Close() // simulate process crash / restart

	// ── Phase 2: reopen the same DB, verify data survives ─────────────────────
	db2, err := openDB(root)
	if err != nil {
		t.Fatalf("phase2 openDB: %v", err)
	}
	defer func() { _ = db2.Close() }()
	if err := initSchema(db2); err != nil {
		t.Fatalf("phase2 initSchema: %v", err)
	}
	m2 := &CheckpointManager{db: db2}

	snap, err := m2.LoadLatest(context.Background(), "t1")
	if err != nil {
		t.Fatalf("phase2 LoadLatest: %v", err)
	}
	if snap == nil {
		t.Fatal("phase2: expected snapshot after restart, got nil")
	}
	if snap.Iteration != 1 {
		t.Errorf("phase2: iteration = %d, want 1", snap.Iteration)
	}
	if len(snap.Messages) != 2 {
		t.Errorf("phase2: len(messages) = %d, want 2", len(snap.Messages))
	}
	if snap.Model != "gemini-2.5-flash" {
		t.Errorf("phase2: model = %q, want %q", snap.Model, "gemini-2.5-flash")
	}
	if snap.Metadata["key"] != "value" {
		t.Errorf("phase2: metadata key = %v, want %q", snap.Metadata["key"], "value")
	}

	// Verify checksum integrity survived the round-trip.
	var checksum string
	if err := db2.QueryRowContext(context.Background(), `SELECT checksum FROM checkpoints WHERE thread_id = 't1'`).Scan(&checksum); err != nil {
		t.Fatalf("phase2: query checksum: %v", err)
	}
	if len(checksum) != 64 {
		t.Errorf("phase2: checksum length = %d, want 64 (SHA-256 hex)", len(checksum))
	}
}

// TestCheckpointManager_CrashAndRecover_MultipleIterations verifies that
// after a restart, LoadLatest returns the HIGHEST iteration saved before crash.
//
//nolint:cyclop // test complexity justified by iteration verification
func TestCheckpointManager_CrashAndRecover_MultipleIterations(t *testing.T) {
	t.Parallel()
	root := t.TempDir()

	db1, err := openDB(root)
	if err != nil {
		t.Fatalf("openDB: %v", err)
	}
	if err := initSchema(db1); err != nil {
		_ = db1.Close()
		t.Fatalf("initSchema: %v", err)
	}
	m1 := &CheckpointManager{db: db1}

	if err := m1.CreateThread(context.Background(), "t1", "model", nil); err != nil {
		t.Fatalf("CreateThread: %v", err)
	}
	for i := 1; i <= 5; i++ {
		msgs := make([]StrategicMessage, i)
		for j := 0; j < i; j++ {
			msgs[j] = StrategicMessage{Role: RoleUser, Content: &MessageContent{Str: strPtr("msg")}}
		}
		if _, err := m1.SaveSnapshot(context.Background(), "t1", i, msgs); err != nil {
			t.Fatalf("SaveSnapshot iter %d: %v", i, err)
		}
	}
	_ = db1.Close() // crash

	db2, err := openDB(root)
	if err != nil {
		t.Fatalf("reopen openDB: %v", err)
	}
	defer func() { _ = db2.Close() }()
	if err := initSchema(db2); err != nil {
		t.Fatalf("reopen initSchema: %v", err)
	}
	m2 := &CheckpointManager{db: db2}

	snap, err := m2.LoadLatest(context.Background(), "t1")
	if err != nil {
		t.Fatalf("LoadLatest: %v", err)
	}
	if snap == nil {
		t.Fatal("expected snapshot, got nil")
	}
	if snap.Iteration != 5 {
		t.Errorf("iteration = %d, want 5", snap.Iteration)
	}
	if len(snap.Messages) != 5 {
		t.Errorf("len(messages) = %d, want 5", len(snap.Messages))
	}
}

// TestCheckpointManager_ConcurrentSaveSnapshot verifies that concurrent
// SaveSnapshot calls from multiple goroutines do not corrupt the database
// and all complete without error.
// This tests the WAL + MaxOpenConns(1) combination that serializes writes.
func TestCheckpointManager_ConcurrentSaveSnapshot(t *testing.T) {
	t.Parallel()
	m := newTestManager(t)
	if err := m.CreateThread(context.Background(), "t1", "model", nil); err != nil {
		t.Fatalf("CreateThread: %v", err)
	}

	const n = 20
	var wg sync.WaitGroup
	errs := make([]error, n)

	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			msgs := []StrategicMessage{
				{Role: RoleUser, Content: &MessageContent{Str: strPtr("msg")}},
			}
			_, errs[idx] = m.SaveSnapshot(context.Background(), "t1", idx+1, msgs)
		}(i)
	}
	wg.Wait()

	for i, err := range errs {
		if err != nil {
			t.Errorf("goroutine %d: SaveSnapshot error: %v", i, err)
		}
	}

	// Verify the DB is still healthy: LoadLatest should succeed.
	snap, err := m.LoadLatest(context.Background(), "t1")
	if err != nil {
		t.Fatalf("LoadLatest after concurrent saves: %v", err)
	}
	if snap == nil {
		t.Fatal("expected non-nil snapshot after concurrent saves")
	}
}

// TestCheckpointManager_ChecksumProtectsAgainstBitrot verifies that if the
// stored state JSON is modified on disk (bit-rot / tampering), LoadLatest
// returns an error rather than silently returning corrupt data.
func TestCheckpointManager_ChecksumProtectsAgainstBitrot(t *testing.T) {
	t.Parallel()
	m := newTestManager(t)
	if err := m.CreateThread(context.Background(), "t1", "model", nil); err != nil {
		t.Fatalf("CreateThread: %v", err)
	}
	msgs := []StrategicMessage{
		{Role: RoleUser, Content: &MessageContent{Str: strPtr("sensitive data")}},
	}
	if _, err := m.SaveSnapshot(context.Background(), "t1", 1, msgs); err != nil {
		t.Fatalf("SaveSnapshot: %v", err)
	}

	// Simulate bit-rot: overwrite state JSON without updating the checksum.
	if _, err := m.db.ExecContext(context.Background(),
		`UPDATE checkpoints SET state = ? WHERE thread_id = ?`,
		`[{"role":"user","content":"tampered"}]`, "t1",
	); err != nil {
		t.Fatalf("tamper state: %v", err)
	}

	_, err := m.LoadLatest(context.Background(), "t1")
	if err == nil {
		t.Error("expected checksum mismatch error for tampered state, got nil")
	}
}
