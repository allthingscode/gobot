//nolint:testpackage // exercises the internal history boundary with existing mocks.
package agent

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/observability"
)

type historyOutcomeStore struct {
	*mockStore
	snapshot                *agentctx.ThreadSnapshot
	cause                   error
	tokenReads, tokenWrites int
}

func (s *historyOutcomeStore) LoadLatest(context.Context, string) (*agentctx.ThreadSnapshot, error) {
	return s.snapshot, s.cause
}

func (s *historyOutcomeStore) GetSessionTokens(context.Context, string) (int, *time.Time, error) {
	s.tokenReads++
	return 0, nil, nil
}

func (s *historyOutcomeStore) UpdateSessionTokens(context.Context, string, int, *time.Time) error {
	s.tokenWrites++
	return nil
}

//nolint:gocognit,cyclop // outcome matrix checks both tracing and per-user resolution paths.
func TestDispatchHistoryLoadFailures(t *testing.T) {
	t.Parallel()
	storageErr := errors.New("storage unavailable")
	cases := []struct {
		name     string
		cause    error
		snapshot *agentctx.ThreadSnapshot
	}{
		{"storage", fmt.Errorf("read: %w", storageErr), nil},
		{"cancelled", context.Canceled, nil},
		{"deadline", context.DeadlineExceeded, nil},
		{"partial", storageErr, &agentctx.ThreadSnapshot{Iteration: 7}},
	}
	for _, tc := range cases {
		for _, traced := range []bool{false, true} {
			for _, perUser := range []bool{false, true} {
				t.Run(fmt.Sprintf("%s/traced=%t/perUser=%t", tc.name, traced, perUser), func(t *testing.T) {
					t.Parallel()
					store := &historyOutcomeStore{mockStore: newMockStore(), snapshot: tc.snapshot, cause: tc.cause}
					runner := &mockRunner{response: "unexpected"}
					mgr := NewSessionManager(runner, store, "model")
					mgr.tokenBudget = 1000
					if traced {
						mgr.SetTracer(observability.NewDispatchTracer(nil))
					}
					if perUser {
						mgr.store = newMockStore()
						mgr.SetCheckpointStoreProvider(func(userID string) (CheckpointStore, error) {
							if userID != "alice" {
								t.Errorf("userID = %q", userID)
							}
							return store, nil
						})
					}
					hookCalls := 0
					hooks := &Hooks{}
					hooks.RegisterPreHistory(func(_ context.Context, messages []agentctx.StrategicMessage) []agentctx.StrategicMessage {
						hookCalls++
						return messages
					})
					mgr.SetHooks(hooks)
					response, err := mgr.Dispatch(context.Background(), t.Name(), "alice", "hello")
					if !errors.Is(err, tc.cause) || !strings.Contains(err.Error(), "load conversation checkpoint") || response != "" {
						t.Fatalf("response=%q error=%v; want wrapped %v", response, err, tc.cause)
					}
					if errors.Is(tc.cause, storageErr) && !errors.Is(err, storageErr) {
						t.Fatal("original storage sentinel lost")
					}
					if len(runner.calls)+len(runner.textCalls)+len(store.createCalls)+store.saveCalls+store.tokenReads+store.tokenWrites+hookCalls != 0 {
						t.Fatal("failed load caused runner, hook, or persistence side effects")
					}
				})
			}
		}
	}
}

//nolint:gocognit,cyclop // table asserts history, persistence, and degradation together.
func TestDispatchHistoryOutcomes(t *testing.T) {
	t.Parallel()
	oldText := "previous conversation"
	history := []agentctx.StrategicMessage{{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: &oldText}}}
	cases := []struct {
		name                      string
		snapshot                  *agentctx.ThreadSnapshot
		nilStore, createFailure   bool
		creates, saves, iteration int
	}{
		{name: "existing", snapshot: &agentctx.ThreadSnapshot{Iteration: 7, Messages: history}, saves: 1, iteration: 8},
		{name: "first", creates: 1, saves: 1, iteration: 1},
		{name: "nil", nilStore: true},
		{name: "degraded", createFailure: true, creates: 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			store := &historyOutcomeStore{mockStore: newMockStore(), snapshot: tc.snapshot}
			if tc.createFailure {
				store.createErr = errors.New("cannot create")
			}
			var activeStore CheckpointStore = store
			if tc.nilStore {
				activeStore = nil
			}
			runner := &mockRunner{response: "ok"}
			mgr := NewSessionManager(runner, activeStore, "model")
			response, err := mgr.Dispatch(context.Background(), t.Name(), "alice", "hello")
			want := "ok"
			if tc.createFailure {
				want = statelessWarning + want
			}
			if err != nil || response != want {
				t.Fatalf("response=%q error=%v", response, err)
			}
			if len(runner.calls) != 1 || len(runner.textCalls) != 0 || len(store.createCalls) != tc.creates || store.saveCalls != tc.saves {
				t.Fatal("unexpected runner or persistence calls")
			}
			if tc.snapshot != nil && runner.calls[0].messages[0].Content.String() != oldText {
				t.Fatal("existing history lost")
			}
			if tc.saves > 0 && store.snapshots[t.Name()].Iteration != tc.iteration {
				t.Fatal("incorrect persisted iteration")
			}
		})
	}
}

// rawHistoryRows captures all columns and rows, including counts and metadata.
func rawHistoryRows(t *testing.T, db *sql.DB) [][]any {
	t.Helper()
	var result [][]any
	for _, query := range []string{"SELECT * FROM checkpoints ORDER BY checkpoint_id", "SELECT * FROM threads ORDER BY thread_id"} {
		rows, err := db.QueryContext(context.Background(), query)
		if err != nil {
			t.Fatal(err)
		}
		columns, err := rows.Columns()
		if err != nil {
			_ = rows.Close()
			t.Fatal(err)
		}
		for rows.Next() {
			values := make([]any, len(columns))
			pointers := make([]any, len(columns))
			for i := range values {
				pointers[i] = &values[i]
			}
			if err := rows.Scan(pointers...); err != nil {
				_ = rows.Close()
				t.Fatal(err)
			}
			result = append(result, values)
		}
		err = rows.Err()
		_ = rows.Close()
		if err != nil {
			t.Fatal(err)
		}
	}
	return result
}

//nolint:cyclop // fixture setup and preservation assertions require explicit error checks.
func TestDispatchCorruptSQLiteHistoryPreserved(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	store, err := agentctx.GetCheckpointManager(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { agentctx.EvictCheckpointManagerForTest(dir) })
	ctx := context.Background()
	key := t.Name()
	if err := store.CreateThread(ctx, key, "original-model", map[string]any{"distinctive": "retain me"}); err != nil {
		t.Fatal(err)
	}
	text := "durable history"
	messages := []agentctx.StrategicMessage{{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: &text}}}
	for _, iteration := range []int{1, 7} {
		if _, err := store.SaveSnapshot(ctx, key, iteration, messages); err != nil {
			t.Fatal(err)
		}
	}
	db, err := sql.Open("sqlite", filepath.Join(dir, "workspace", "checkpoints.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if _, err := db.ExecContext(ctx, "UPDATE checkpoints SET checksum = 'corrupt' WHERE iteration = 7"); err != nil {
		t.Fatal(err)
	}
	before := rawHistoryRows(t, db)
	runner := &mockRunner{response: "unexpected"}
	mgr := NewSessionManager(runner, store, "replacement-model")
	mgr.tokenBudget = 1000
	response, err := mgr.Dispatch(ctx, key, "alice", "hello")
	if err == nil || !strings.Contains(err.Error(), "load conversation checkpoint: LoadLatest: checksum mismatch") || response != "" {
		t.Fatalf("response=%q error=%v", response, err)
	}
	if len(runner.calls)+len(runner.textCalls) != 0 {
		t.Fatal("runner executed after corruption")
	}
	if after := rawHistoryRows(t, db); !reflect.DeepEqual(before, after) {
		t.Fatalf("persisted rows changed: before=%v after=%v", before, after)
	}
	if _, err := store.LoadLatest(ctx, key); err == nil || !strings.Contains(err.Error(), "checksum mismatch") {
		t.Fatalf("corruption no longer observable: %v", err)
	}
}
