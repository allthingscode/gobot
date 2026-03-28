package context

import (
	"os"
	"sync"
	"testing"
)

// newTestManager creates an isolated CheckpointManager backed by a temp DB.
// It bypasses the singleton so each test gets a clean database.
func newTestManager(t *testing.T) *CheckpointManager {
	t.Helper()
	root := t.TempDir()
	db, err := openDB(root)
	if err != nil {
		t.Fatalf("openDB: %v", err)
	}
	if err := initSchema(db); err != nil {
		t.Fatalf("initSchema: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	return &CheckpointManager{db: db}
}

// strPtr is a helper to take the address of a string literal.
func strPtr(s string) *string { return &s }

// ── CreateThread ──────────────────────────────────────────────────────────────

func TestCreateThread(t *testing.T) {
	tests := []struct {
		name     string
		threadID string
		model    string
		metadata map[string]any
		wantErr  bool
	}{
		{
			name:     "basic creation",
			threadID: "t1",
			model:    "gemini-3-flash",
			metadata: map[string]any{"session": "abc"},
		},
		{
			name:     "nil metadata defaults to empty map",
			threadID: "t2",
			model:    "gemini-3-flash",
			metadata: nil,
		},
		{
			name:     "replace existing thread",
			threadID: "t3",
			model:    "gemini-3-pro",
			metadata: map[string]any{},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			m := newTestManager(t)
			if err := m.CreateThread(tt.threadID, tt.model, tt.metadata); (err != nil) != tt.wantErr {
				t.Errorf("CreateThread() error = %v, wantErr %v", err, tt.wantErr)
			}
			// Re-inserting the same thread_id must not error (INSERT OR REPLACE).
			if err := m.CreateThread(tt.threadID, tt.model+"v2", nil); err != nil {
				t.Errorf("re-insert: %v", err)
			}
		})
	}
}

// ── SaveSnapshot ─────────────────────────────────────────────────────────────

func TestSaveSnapshot(t *testing.T) {
	msg := func(role, text string) StrategicMessage {
		content := MessageContent{Str: strPtr(text)}
		return StrategicMessage{Role: role, Content: &content}
	}

	tests := []struct {
		name      string
		threadID  string
		iteration int
		messages  []StrategicMessage
		wantOK    bool
	}{
		{
			name:      "saves valid snapshot",
			threadID:  "t1",
			iteration: 1,
			messages:  []StrategicMessage{msg("user", "hello"), msg("assistant", "hi")},
			wantOK:    true,
		},
		{
			name:      "empty messages list",
			threadID:  "t2",
			iteration: 0,
			messages:  []StrategicMessage{},
			wantOK:    true,
		},
		{
			name:      "nil messages slice",
			threadID:  "t3",
			iteration: 0,
			messages:  nil,
			wantOK:    true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			m := newTestManager(t)
			if err := m.CreateThread(tt.threadID, "model", nil); err != nil {
				t.Fatalf("CreateThread: %v", err)
			}
			ok, err := m.SaveSnapshot(tt.threadID, tt.iteration, tt.messages)
			if err != nil {
				t.Errorf("SaveSnapshot() unexpected error: %v", err)
			}
			if ok != tt.wantOK {
				t.Errorf("SaveSnapshot() ok = %v, want %v", ok, tt.wantOK)
			}
		})
	}
}

// ── LoadLatest ────────────────────────────────────────────────────────────────

func TestLoadLatest(t *testing.T) {
	msg := func(role, text string) StrategicMessage {
		content := MessageContent{Str: strPtr(text)}
		return StrategicMessage{Role: role, Content: &content}
	}

	t.Run("returns nil for unknown thread", func(t *testing.T) {
		m := newTestManager(t)
		snap, err := m.LoadLatest("no-such-thread")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if snap != nil {
			t.Errorf("expected nil snapshot, got %+v", snap)
		}
	})

	t.Run("returns latest iteration when multiple snapshots exist", func(t *testing.T) {
		m := newTestManager(t)
		if err := m.CreateThread("t1", "gemini-3-flash", map[string]any{"k": "v"}); err != nil {
			t.Fatalf("CreateThread: %v", err)
		}
		msgs1 := []StrategicMessage{msg("user", "first")}
		msgs2 := []StrategicMessage{msg("user", "first"), msg("assistant", "second")}
		if _, err := m.SaveSnapshot("t1", 1, msgs1); err != nil {
			t.Fatalf("SaveSnapshot iter1: %v", err)
		}
		if _, err := m.SaveSnapshot("t1", 2, msgs2); err != nil {
			t.Fatalf("SaveSnapshot iter2: %v", err)
		}

		snap, err := m.LoadLatest("t1")
		if err != nil {
			t.Fatalf("LoadLatest: %v", err)
		}
		if snap == nil {
			t.Fatal("expected snapshot, got nil")
		}
		if snap.Iteration != 2 {
			t.Errorf("expected iteration 2, got %d", snap.Iteration)
		}
		if len(snap.Messages) != 2 {
			t.Errorf("expected 2 messages, got %d", len(snap.Messages))
		}
		if snap.Model != "gemini-3-flash" {
			t.Errorf("expected model gemini-3-flash, got %q", snap.Model)
		}
		if snap.Metadata["k"] != "v" {
			t.Errorf("expected metadata k=v, got %v", snap.Metadata)
		}
	})

	t.Run("messages round-trip correctly", func(t *testing.T) {
		m := newTestManager(t)
		if err := m.CreateThread("t1", "m", nil); err != nil {
			t.Fatalf("CreateThread: %v", err)
		}
		original := []StrategicMessage{
			msg("user", "hello"),
			msg("assistant", "world"),
		}
		if _, err := m.SaveSnapshot("t1", 1, original); err != nil {
			t.Fatalf("SaveSnapshot: %v", err)
		}
		snap, err := m.LoadLatest("t1")
		if err != nil {
			t.Fatalf("LoadLatest: %v", err)
		}
		for i, got := range snap.Messages {
			want := original[i]
			if got.Role != want.Role {
				t.Errorf("msg[%d].Role = %q, want %q", i, got.Role, want.Role)
			}
			if got.Content.Str == nil || *got.Content.Str != *want.Content.Str {
				t.Errorf("msg[%d].Content mismatch", i)
			}
		}
	})
}

// ── CompleteThread ────────────────────────────────────────────────────────────

func TestCompleteThread(t *testing.T) {
	t.Run("marks thread as completed", func(t *testing.T) {
		m := newTestManager(t)
		if err := m.CreateThread("t1", "model", nil); err != nil {
			t.Fatalf("CreateThread: %v", err)
		}
		if err := m.CompleteThread("t1"); err != nil {
			t.Fatalf("CompleteThread: %v", err)
		}
		var status string
		if err := m.db.QueryRow("SELECT status FROM threads WHERE thread_id = ?", "t1").Scan(&status); err != nil {
			t.Fatalf("query status: %v", err)
		}
		if status != "completed" {
			t.Errorf("expected status 'completed', got %q", status)
		}
	})

	t.Run("completed thread excluded from ListResumable", func(t *testing.T) {
		m := newTestManager(t)
		if err := m.CreateThread("t1", "m", nil); err != nil {
			t.Fatalf("CreateThread: %v", err)
		}
		content := MessageContent{Str: strPtr("hi")}
		if _, err := m.SaveSnapshot("t1", 1, []StrategicMessage{{Role: "user", Content: &content}}); err != nil {
			t.Fatalf("SaveSnapshot: %v", err)
		}
		if err := m.CompleteThread("t1"); err != nil {
			t.Fatalf("CompleteThread: %v", err)
		}
		resumable, err := m.ListResumable()
		if err != nil {
			t.Fatalf("ListResumable: %v", err)
		}
		if len(resumable) != 0 {
			t.Errorf("expected empty list, got %+v", resumable)
		}
	})
}

// ── ListResumable ─────────────────────────────────────────────────────────────

func TestListResumable(t *testing.T) {
	t.Run("returns empty list when no threads", func(t *testing.T) {
		m := newTestManager(t)
		result, err := m.ListResumable()
		if err != nil {
			t.Fatalf("ListResumable: %v", err)
		}
		if len(result) != 0 {
			t.Errorf("expected empty, got %v", result)
		}
	})

	t.Run("returns active threads with snapshots ordered by updated_at desc", func(t *testing.T) {
		m := newTestManager(t)
		content := MessageContent{Str: strPtr("msg")}
		snap := []StrategicMessage{{Role: "user", Content: &content}}

		for _, id := range []string{"tA", "tB"} {
			if err := m.CreateThread(id, "model", nil); err != nil {
				t.Fatalf("CreateThread %s: %v", id, err)
			}
			if _, err := m.SaveSnapshot(id, 1, snap); err != nil {
				t.Fatalf("SaveSnapshot %s: %v", id, err)
			}
		}

		result, err := m.ListResumable()
		if err != nil {
			t.Fatalf("ListResumable: %v", err)
		}
		if len(result) != 2 {
			t.Errorf("expected 2 results, got %d", len(result))
		}
		for _, r := range result {
			if r.LatestIteration != 1 {
				t.Errorf("thread %s: expected LatestIteration=1, got %d", r.ThreadID, r.LatestIteration)
			}
		}
	})

	t.Run("thread without snapshot not included", func(t *testing.T) {
		m := newTestManager(t)
		if err := m.CreateThread("no-snap", "model", nil); err != nil {
			t.Fatalf("CreateThread: %v", err)
		}
		result, err := m.ListResumable()
		if err != nil {
			t.Fatalf("ListResumable: %v", err)
		}
		if len(result) != 0 {
			t.Errorf("expected empty, got %v", result)
		}
	})
}

// ── Closed-DB error paths ─────────────────────────────────────────────────────

func TestSaveSnapshot_TxBeginError(t *testing.T) {
	m := newTestManager(t)
	if err := m.CreateThread("t1", "model", nil); err != nil {
		t.Fatalf("CreateThread: %v", err)
	}
	m.db.Close() // force all subsequent DB operations to fail

	content := MessageContent{Str: strPtr("hi")}
	msgs := []StrategicMessage{{Role: "user", Content: &content}}
	_, err := m.SaveSnapshot("t1", 1, msgs)
	if err == nil {
		t.Error("expected error after DB close, got nil")
	}
}

func TestListResumable_QueryError(t *testing.T) {
	m := newTestManager(t)
	m.db.Close() // force query to fail

	_, err := m.ListResumable()
	if err == nil {
		t.Error("expected error after DB close, got nil")
	}
}

func TestCreateThread_ExecError(t *testing.T) {
	m := newTestManager(t)
	m.db.Close()

	if err := m.CreateThread("t1", "model", nil); err == nil {
		t.Error("expected error after DB close, got nil")
	}
}

func TestCompleteThread_ExecError(t *testing.T) {
	m := newTestManager(t)
	m.db.Close()

	if err := m.CompleteThread("t1"); err == nil {
		t.Error("expected error after DB close, got nil")
	}
}

// ── LoadLatest error paths ────────────────────────────────────────────────────

func TestLoadLatest_CorruptState(t *testing.T) {
	t.Run("returns error when state JSON is corrupt", func(t *testing.T) {
		m := newTestManager(t)
		if err := m.CreateThread("t1", "model", nil); err != nil {
			t.Fatalf("CreateThread: %v", err)
		}
		// Insert a checkpoint with invalid JSON in the state column.
		if _, err := m.db.Exec(
			`INSERT INTO checkpoints (thread_id, iteration, state) VALUES (?, ?, ?)`,
			"t1", 1, "NOT_VALID_JSON",
		); err != nil {
			t.Fatalf("insert corrupt row: %v", err)
		}
		_, err := m.LoadLatest("t1")
		if err == nil {
			t.Error("expected error for corrupt state JSON, got nil")
		}
	})
}

func TestLoadLatest_CorruptMetadata(t *testing.T) {
	t.Run("falls back to empty map when metadata JSON is corrupt", func(t *testing.T) {
		m := newTestManager(t)
		// Insert a thread with invalid metadata JSON directly.
		if _, err := m.db.Exec(
			`INSERT INTO threads (thread_id, model, status, metadata) VALUES (?, ?, 'active', ?)`,
			"t1", "model", "NOT_JSON",
		); err != nil {
			t.Fatalf("insert corrupt thread: %v", err)
		}
		content := MessageContent{Str: strPtr("hi")}
		if _, err := m.db.Exec(
			`INSERT INTO checkpoints (thread_id, iteration, state) VALUES (?, ?, ?)`,
			"t1", 1, `[{"role":"user","content":"hi"}]`,
		); err != nil {
			t.Fatalf("insert checkpoint: %v", err)
		}
		snap, err := m.LoadLatest("t1")
		_ = content
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if snap == nil {
			t.Fatal("expected snapshot, got nil")
		}
		// Corrupt metadata should fall back to empty map.
		if snap.Metadata == nil || len(snap.Metadata) != 0 {
			t.Errorf("expected empty metadata map, got %v", snap.Metadata)
		}
	})
}

// ── SaveSnapshot validation path ──────────────────────────────────────────────

func TestSaveSnapshot_UnmarshalableMarshal(t *testing.T) {
	// StrategicMessage with a channel (or func) in ToolCalls cannot marshal.
	// The simplest way to exercise the marshal-returns-false path is to pass
	// a message whose Content is set to an item whose MarshalJSON returns an error.
	// We use a ContentItem with all-nil fields to trigger that error path.
	m := newTestManager(t)
	if err := m.CreateThread("t1", "model", nil); err != nil {
		t.Fatalf("CreateThread: %v", err)
	}

	// ContentItem with all-nil fields: MarshalJSON returns an error.
	badItem := ContentItem{} // all nil
	msgs := []StrategicMessage{
		{Role: "user", Content: &MessageContent{Items: []ContentItem{badItem}}},
	}
	ok, err := m.SaveSnapshot("t1", 1, msgs)
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	if ok {
		t.Error("expected ok=false for un-marshalable messages, got true")
	}
}

// ── GetCheckpointManager singleton ───────────────────────────────────────────

func resetSingleton() {
	cmOnce = sync.Once{}
	cmInstance = nil
	cmInitErr = nil
}

func TestGetCheckpointManager_Error(t *testing.T) {
	t.Run("returns error when storage root is not creatable", func(t *testing.T) {
		resetSingleton()
		root := t.TempDir()
		t.Cleanup(resetSingleton)

		// Block workspace dir creation by placing a file at that path.
		blocker := root + "/workspace"
		if err := os.WriteFile(blocker, []byte("x"), 0o644); err != nil {
			t.Fatalf("setup: %v", err)
		}
		m, err := GetCheckpointManager(root)
		if err == nil {
			if m != nil {
				m.db.Close()
			}
			t.Error("expected error, got nil")
		}
	})
}

func TestGetCheckpointManager_Singleton(t *testing.T) {
	// Reset the singleton state for this test.
	cmOnce = sync.Once{}
	cmInstance = nil
	cmInitErr = nil

	// TempDir cleanup must be registered BEFORE our DB-close cleanup so that
	// LIFO ordering closes the DB first, then removes the directory.
	root := t.TempDir()
	t.Cleanup(func() {
		if cmInstance != nil {
			cmInstance.db.Close()
		}
		cmOnce = sync.Once{}
		cmInstance = nil
		cmInitErr = nil
	})
	m1, err := GetCheckpointManager(root)
	if err != nil {
		t.Fatalf("first call: %v", err)
	}
	m2, err := GetCheckpointManager(root + "/ignored")
	if err != nil {
		t.Fatalf("second call: %v", err)
	}
	if m1 != m2 {
		t.Error("expected same instance on second call (singleton)")
	}
}

// ── Checksum tests ────────────────────────────────────────────────────────────

func TestSaveSnapshot_StoresChecksum(t *testing.T) {
	m := newTestManager(t)
	if err := m.CreateThread("t1", "model", nil); err != nil {
		t.Fatalf("CreateThread: %v", err)
	}
	content := MessageContent{Str: strPtr("hello")}
	msgs := []StrategicMessage{{Role: "user", Content: &content}}
	ok, err := m.SaveSnapshot("t1", 1, msgs)
	if err != nil {
		t.Fatalf("SaveSnapshot: %v", err)
	}
	if !ok {
		t.Fatal("expected ok=true")
	}

	var checksum string
	if err := m.db.QueryRow(`SELECT checksum FROM checkpoints WHERE thread_id = 't1'`).Scan(&checksum); err != nil {
		t.Fatalf("query checksum: %v", err)
	}
	if checksum == "" {
		t.Error("expected non-empty checksum")
	}
	if len(checksum) != 64 {
		t.Errorf("expected checksum length 64 (SHA-256 hex), got %d: %q", len(checksum), checksum)
	}
}

func TestLoadLatest_ChecksumMismatch(t *testing.T) {
	m := newTestManager(t)
	if err := m.CreateThread("t1", "model", nil); err != nil {
		t.Fatalf("CreateThread: %v", err)
	}
	content := MessageContent{Str: strPtr("hello")}
	msgs := []StrategicMessage{{Role: "user", Content: &content}}
	if _, err := m.SaveSnapshot("t1", 1, msgs); err != nil {
		t.Fatalf("SaveSnapshot: %v", err)
	}

	// Corrupt the stored checksum.
	m.db.Exec(`UPDATE checkpoints SET checksum = ? WHERE thread_id = ?`, "deadbeef", "t1")

	_, err := m.LoadLatest("t1")
	if err == nil {
		t.Error("expected error due to checksum mismatch, got nil")
	}
}

func TestLoadLatest_NullChecksum_LegacyCompat(t *testing.T) {
	m := newTestManager(t)
	if err := m.CreateThread("t1", "model", nil); err != nil {
		t.Fatalf("CreateThread: %v", err)
	}
	// Insert a legacy checkpoint row without the checksum column (defaults to NULL).
	m.db.Exec(`INSERT INTO checkpoints (thread_id, iteration, state) VALUES (?, ?, ?)`,
		"t1", 1, `[{"role":"user","content":"hi"}]`)

	snap, err := m.LoadLatest("t1")
	if err != nil {
		t.Fatalf("expected nil error for legacy row, got: %v", err)
	}
	if snap == nil {
		t.Fatal("expected non-nil snapshot for legacy row, got nil")
	}
}
