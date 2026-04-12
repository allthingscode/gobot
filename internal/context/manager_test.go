package context

import (
	"bytes"
	"log/slog"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

// Test helper variables for singleton reset (used by resetSingleton).
var (
	cmOnce     sync.Once
	cmInstance *CheckpointManager
	cmInitErr  error
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
	t.Cleanup(func() { _ = db.Close() })
	return &CheckpointManager{db: db}
}

// strPtr is a helper to take the address of a string literal.
func strPtr(s string) *string { return &s }

// ── CreateThread ──────────────────────────────────────────────────────────────

func TestCreateThread(t *testing.T) { //nolint:paralleltest // modifies global environment

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
			t.Parallel()

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

func TestSaveSnapshot(t *testing.T) { //nolint:paralleltest // modifies global environment

	msg := func(role MessageRole, text string) StrategicMessage {
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
			messages:  []StrategicMessage{msg(RoleUser, "hello"), msg(RoleAssistant, "hi")},
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
			t.Parallel()

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

func TestLoadLatest(t *testing.T) { //nolint:paralleltest // modifies global environment

	msg := func(role MessageRole, text string) StrategicMessage {
		content := MessageContent{Str: strPtr(text)}
		return StrategicMessage{Role: role, Content: &content}
	}

	t.Run("returns nil for unknown thread", func(t *testing.T) {
		t.Parallel()

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
		t.Parallel()

		m := newTestManager(t)
		if err := m.CreateThread("t1", "gemini-3-flash", map[string]any{"k": "v"}); err != nil {
			t.Fatalf("CreateThread: %v", err)
		}
		msgs1 := []StrategicMessage{msg(RoleUser, "first")}
		msgs2 := []StrategicMessage{msg(RoleUser, "first"), msg(RoleAssistant, "second")}
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
		t.Parallel()

		m := newTestManager(t)
		if err := m.CreateThread("t1", "m", nil); err != nil {
			t.Fatalf("CreateThread: %v", err)
		}
		original := []StrategicMessage{
			msg(RoleUser, "hello"),
			msg(RoleAssistant, "world"),
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

func TestCompleteThread(t *testing.T) { //nolint:paralleltest // modifies global environment

	t.Run("marks thread as completed", func(t *testing.T) {
		t.Parallel()

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
		t.Parallel()

		m := newTestManager(t)
		if err := m.CreateThread("t1", "m", nil); err != nil {
			t.Fatalf("CreateThread: %v", err)
		}
		content := MessageContent{Str: strPtr("hi")}
		if _, err := m.SaveSnapshot("t1", 1, []StrategicMessage{{Role: RoleUser, Content: &content}}); err != nil {
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

func TestListResumable(t *testing.T) { //nolint:paralleltest // modifies global environment

	t.Run("returns empty list when no threads", func(t *testing.T) {
		t.Parallel()

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
		t.Parallel()

		m := newTestManager(t)
		content := MessageContent{Str: strPtr("msg")}
		snap := []StrategicMessage{{Role: RoleUser, Content: &content}}

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
		t.Parallel()

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

func TestSaveSnapshot_TxBeginError(t *testing.T) { //nolint:paralleltest // modifies global environment

	m := newTestManager(t)
	if err := m.CreateThread("t1", "model", nil); err != nil {
		t.Fatalf("CreateThread: %v", err)
	}
	_ = m.db.Close() // force all subsequent DB operations to fail

	content := MessageContent{Str: strPtr("hi")}
	msgs := []StrategicMessage{{Role: RoleUser, Content: &content}}
	_, err := m.SaveSnapshot("t1", 1, msgs)
	if err == nil {
		t.Error("expected error after DB close, got nil")
	}
}

func TestListResumable_QueryError(t *testing.T) { //nolint:paralleltest // modifies global environment

	m := newTestManager(t)
	_ = m.db.Close() // force query to fail

	_, err := m.ListResumable()
	if err == nil {
		t.Error("expected error after DB close, got nil")
	}
}

func TestCreateThread_ExecError(t *testing.T) { //nolint:paralleltest // modifies global environment

	m := newTestManager(t)
	_ = m.db.Close()

	err := m.CreateThread("t1", "model", nil)
	if err == nil {
		t.Error("expected error after DB close, got nil")
	}
	expected := "CreateThread: exec:"
	if !strings.Contains(err.Error(), expected) {
		t.Errorf("expected error to contain %q, got %q", expected, err.Error())
	}
}

func TestCompleteThread_ExecError(t *testing.T) { //nolint:paralleltest // modifies global environment

	m := newTestManager(t)
	_ = m.db.Close()

	err := m.CompleteThread("t1")
	if err == nil {
		t.Error("expected error after DB close, got nil")
	}
	expected := "CompleteThread: exec:"
	if !strings.Contains(err.Error(), expected) {
		t.Errorf("expected error to contain %q, got %q", expected, err.Error())
	}
}

// ── LoadLatest error paths ────────────────────────────────────────────────────

func TestLoadLatest_CorruptState(t *testing.T) { //nolint:paralleltest // modifies global environment

	t.Run("returns error when state JSON is corrupt", func(t *testing.T) {
		t.Parallel()
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

func TestLoadLatest_CorruptMetadata(t *testing.T) { //nolint:paralleltest // modifies global environment

	t.Run("falls back to empty map when metadata JSON is corrupt", func(t *testing.T) {
		t.Parallel()
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

func TestSaveSnapshot_UnmarshalableMarshal(t *testing.T) { //nolint:paralleltest // modifies global environment

	// StrategicMessage with a channel (or func) in ToolCalls cannot marshal.
	// The simplest way to exercise the marshal-returns-false path is to pass
	// a message whose Content is set to an item whose MarshalJSON returns an error.
	// We use a ContentItem with all-nil fields to trigger that error path.
	m := newTestManager(t)
	if err := m.CreateThread("t1", "model", nil); err != nil {
		t.Fatalf("CreateThread: %v", err)
	}

	// Set up a custom slog handler to capture output.
	var buf bytes.Buffer
	handler := slog.NewTextHandler(&buf, nil)
	oldDefault := slog.Default()
	slog.SetDefault(slog.New(handler))
	t.Cleanup(func() { slog.SetDefault(oldDefault) })

	// ContentItem with all-nil fields: MarshalJSON returns an error.
	badItem := ContentItem{} // all nil
	msgs := []StrategicMessage{
		{Role: RoleUser, Content: &MessageContent{Items: []ContentItem{badItem}}},
	}
	ok, err := m.SaveSnapshot("t1", 1, msgs)
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	if ok {
		t.Error("expected ok=false for un-marshalable messages, got true")
	}

	// Verify log contains the warning and our session ID.
	output := buf.String()
	if !bytes.Contains(buf.Bytes(), []byte("level=WARN")) {
		t.Errorf("expected level=WARN log, got: %q", output)
	}
	if !bytes.Contains(buf.Bytes(), []byte("session=t1")) {
		t.Errorf("expected session=t1 in log, got: %q", output)
	}
	if !bytes.Contains(buf.Bytes(), []byte("ContentItem: all fields are nil")) {
		t.Errorf("expected reason in log, got: %q", output)
	}
}

// ── GetCheckpointManager singleton ───────────────────────────────────────────

func resetSingleton() {
	resetCheckpointManagerInstances()
}

func TestGetCheckpointManager_Error(t *testing.T) { //nolint:paralleltest // modifies global environment

	t.Run("returns error when storage root is not creatable", func(t *testing.T) {
		t.Parallel()
		resetSingleton()
		root := t.TempDir()
		t.Cleanup(resetSingleton)

		// Block workspace dir creation by placing a file at that path.
		blocker := root + "/workspace"
		if err := os.WriteFile(blocker, []byte("x"), 0o600); err != nil {
			t.Fatalf("setup: %v", err)
		}
		m, err := GetCheckpointManager(root)
		if err == nil {
			if m != nil {
				_ = m.db.Close()
			}
			t.Error("expected error, got nil")
		}
	})
}

func TestGetCheckpointManager_Singleton(t *testing.T) { //nolint:paralleltest // modifies global environment

	// Reset the singleton state for this test.
	cmOnce = sync.Once{}
	cmInstance = nil
	cmInitErr = nil

	// TempDir cleanup must be registered BEFORE our DB-close cleanup so that
	// LIFO ordering closes the DB first, then removes the directory.
	root := t.TempDir()
	t.Cleanup(resetSingleton)
	m1, err := GetCheckpointManager(root)
	if err != nil {
		t.Fatalf("first call: %v", err)
	}
	m2, err := GetCheckpointManager(root)
	if err != nil {
		t.Fatalf("second call: %v", err)
	}
	if m1 != m2 {
		t.Error("expected same instance on second call (per-directory caching)")
	}
}

// ── Checksum tests ────────────────────────────────────────────────────────────

func TestSaveSnapshot_StoresChecksum(t *testing.T) { //nolint:paralleltest // modifies global environment

	m := newTestManager(t)
	if err := m.CreateThread("t1", "model", nil); err != nil {
		t.Fatalf("CreateThread: %v", err)
	}
	content := MessageContent{Str: strPtr("hello")}
	msgs := []StrategicMessage{{Role: RoleUser, Content: &content}}
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

func TestLoadLatest_ChecksumMismatch(t *testing.T) { //nolint:paralleltest // modifies global environment

	m := newTestManager(t)
	if err := m.CreateThread("t1", "model", nil); err != nil {
		t.Fatalf("CreateThread: %v", err)
	}
	content := MessageContent{Str: strPtr("hello")}
	msgs := []StrategicMessage{{Role: RoleUser, Content: &content}}
	if _, err := m.SaveSnapshot("t1", 1, msgs); err != nil {
		t.Fatalf("SaveSnapshot: %v", err)
	}

	// Corrupt the stored checksum.
	if _, err := m.db.Exec(`UPDATE checkpoints SET checksum = ? WHERE thread_id = ?`, "deadbeef", "t1"); err != nil {
		t.Fatalf("UPDATE failed: %v", err)
	}

	_, err := m.LoadLatest("t1")
	if err == nil {
		t.Error("expected error due to checksum mismatch, got nil")
	}
}

func TestLoadLatest_NullChecksum_LegacyCompat(t *testing.T) { //nolint:paralleltest // modifies global environment

	m := newTestManager(t)
	if err := m.CreateThread("t1", "model", nil); err != nil {
		t.Fatalf("CreateThread: %v", err)
	}
	// Insert a legacy checkpoint row without the checksum column (defaults to NULL).
	if _, err := m.db.Exec(`INSERT INTO checkpoints (thread_id, iteration, state) VALUES (?, ?, ?)`,
		"t1", 1, `[{"role":"user","content":"hi"}]`); err != nil {
		t.Fatalf("INSERT failed: %v", err)
	}

	snap, err := m.LoadLatest("t1")
	if err != nil {
		t.Fatalf("expected nil error for legacy row, got: %v", err)
	}
	if snap == nil {
		t.Fatal("expected non-nil snapshot for legacy row, got nil")
	}
}

func TestLoadLatest_IndexUsage(t *testing.T) { //nolint:paralleltest // isolated by newTestManager, but sticking to convention
	m := newTestManager(t)
	if err := m.CreateThread("tidx", "model", nil); err != nil {
		t.Fatalf("CreateThread: %v", err)
	}

	// Insert some checkpoints
	for i := 1; i <= 5; i++ {
		if _, err := m.SaveSnapshot("tidx", i, []StrategicMessage{
			{Role: RoleUser, Content: &MessageContent{Str: strPtr("test")}},
		}); err != nil {
			t.Fatalf("SaveSnapshot: %v", err)
		}
	}

	// Run EXPLAIN QUERY PLAN on the exact query used in LoadLatest
	query := `EXPLAIN QUERY PLAN SELECT iteration, state, checksum FROM checkpoints
		 WHERE thread_id = 'tidx'
		 ORDER BY iteration DESC, checkpoint_id DESC
		 LIMIT 1`

	rows, err := m.db.Query(query)
	if err != nil {
		t.Fatalf("EXPLAIN QUERY PLAN failed: %v", err)
	}
	defer func() { _ = rows.Close() }()

	var usedIndex bool
	for rows.Next() {
		var id, parent, notused int
		var detail string
		if err := rows.Scan(&id, &parent, &notused, &detail); err != nil {
			t.Fatalf("scan plan: %v", err)
		}
		if strings.Contains(detail, "USING INDEX idx_checkpoints_thread_iteration") {
			usedIndex = true
			break
		}
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("rows error: %v", err)
	}

	if !usedIndex {
		t.Error("Expected LoadLatest query to use idx_checkpoints_thread_iteration, but it did not. Check query plan.")
	}
}

func TestUpdateSessionTokens(t *testing.T) { //nolint:paralleltest // uses newTestManager isolation
	m := newTestManager(t)
	if err := m.CreateThread("t1", "model", nil); err != nil {
		t.Fatalf("CreateThread: %v", err)
	}

	// Update tokens for session.
	if err := m.UpdateSessionTokens("t1", 5000, nil); err != nil {
		t.Fatalf("UpdateSessionTokens: %v", err)
	}

	// Verify tokens were stored.
	tokens, compactedAt, err := m.GetSessionTokens("t1")
	if err != nil {
		t.Fatalf("GetSessionTokens: %v", err)
	}
	if tokens != 5000 {
		t.Errorf("expected tokens=5000, got %d", tokens)
	}
	if compactedAt != nil {
		t.Errorf("expected nil compactedAt, got %v", compactedAt)
	}
}

func TestUpdateSessionTokens_WithCompactedAt(t *testing.T) { //nolint:paralleltest // isolated via newTestManager
	m := newTestManager(t)
	if err := m.CreateThread("t1", "model", nil); err != nil {
		t.Fatalf("CreateThread: %v", err)
	}

	compactTime := time.Date(2026, 4, 11, 20, 0, 0, 0, time.UTC)
	if err := m.UpdateSessionTokens("t1", 10000, &compactTime); err != nil {
		t.Fatalf("UpdateSessionTokens: %v", err)
	}

	tokens, compactedAt, err := m.GetSessionTokens("t1")
	if err != nil {
		t.Fatalf("GetSessionTokens: %v", err)
	}
	if tokens != 10000 {
		t.Errorf("expected tokens=10000, got %d", tokens)
	}
	if compactedAt == nil {
		t.Fatal("expected non-nil compactedAt")
	}
	if !compactedAt.Equal(compactTime) {
		t.Errorf("expected compactedAt=%v, got %v", compactTime, compactedAt)
	}
}

func TestGetSessionTokens_UnknownSession(t *testing.T) { //nolint:paralleltest // isolated via newTestManager
	m := newTestManager(t)
	tokens, compactedAt, err := m.GetSessionTokens("unknown-session")
	if err != nil {
		t.Fatalf("GetSessionTokens: unexpected error: %v", err)
	}
	if tokens != 0 {
		t.Errorf("expected tokens=0, got %d", tokens)
	}
	if compactedAt != nil {
		t.Errorf("expected nil compactedAt, got %v", compactedAt)
	}
}

func TestUpdateSessionTokens_UpdatesExistingRow(t *testing.T) { //nolint:paralleltest // isolated via newTestManager
	m := newTestManager(t)
	if err := m.CreateThread("t1", "model", nil); err != nil {
		t.Fatalf("CreateThread: %v", err)
	}

	// First update.
	if err := m.UpdateSessionTokens("t1", 1000, nil); err != nil {
		t.Fatalf("UpdateSessionTokens: %v", err)
	}
	// Second update (should overwrite).
	if err := m.UpdateSessionTokens("t1", 2000, nil); err != nil {
		t.Fatalf("UpdateSessionTokens: %v", err)
	}

	tokens, _, err := m.GetSessionTokens("t1")
	if err != nil {
		t.Fatalf("GetSessionTokens: %v", err)
	}
	if tokens != 2000 {
		t.Errorf("expected tokens=2000 (latest update), got %d", tokens)
	}
}
