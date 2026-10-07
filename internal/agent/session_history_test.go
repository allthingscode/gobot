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

const checkpointTestReply = "completed"

type saveOutcomeStore struct {
	*mockStore
	cancel   context.CancelFunc
	deadline bool
}

func (s *saveOutcomeStore) SaveSnapshot(ctx context.Context, key string, iteration int, messages []agentctx.StrategicMessage) (bool, error) {
	if s.cancel != nil {
		s.cancel()
		s.saveErr = ctx.Err()
	}
	if s.deadline {
		s.saveErr = context.DeadlineExceeded
	}
	return s.mockStore.SaveSnapshot(ctx, key, iteration, messages)
}

type saveOutcomeRunner struct {
	*mockRunner
	empty bool
}

func (r *saveOutcomeRunner) Run(ctx context.Context, key, user string, messages []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error) {
	response, updated, err := r.mockRunner.Run(ctx, key, user, messages)
	if r.empty {
		updated = nil
	}
	return response, updated, err
}

//nolint:gocognit,cyclop // matrix verifies response decoration and side effects together.
func TestDispatchCheckpointSaveOutcomes(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name                                               string
		fail, cancel, deadline, nilStore, stateless, empty bool
	}{
		{name: "success"},
		{name: "failure", fail: true},
		{name: "cancelled at save", cancel: true},
		{name: "deadline at save", deadline: true},
		{name: "nil store", nilStore: true},
		{name: "stateless", stateless: true},
		{name: "empty history", empty: true},
	}
	for _, tc := range cases {
		for _, hooked := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/hooked=%t", tc.name, hooked), func(t *testing.T) {
				t.Parallel()
				ctx, cancel := context.WithCancel(context.Background())
				defer cancel()
				store := &saveOutcomeStore{mockStore: newMockStore(), deadline: tc.deadline}
				if tc.cancel {
					store.cancel = cancel
				}
				if tc.fail {
					store.saveErr = errors.New("secret-token at /private/checkpoints.db")
				}
				if tc.stateless {
					store.createErr = errors.New("cannot initialize")
				}
				var activeStore CheckpointStore = store
				if tc.nilStore {
					activeStore = nil
				}
				runner := &saveOutcomeRunner{mockRunner: &mockRunner{response: checkpointTestReply}, empty: tc.empty}
				mgr := NewSessionManager(runner, activeStore, "model")
				hookCalls := 0
				body := checkpointTestReply
				if hooked {
					body = "replacement"
					hooks := &Hooks{}
					hooks.RegisterPostDispatch(func(_ context.Context, key, response string) string {
						hookCalls++
						if key != t.Name() || response != checkpointTestReply || store.saveCalls != btoi(!tc.nilStore && !tc.stateless && !tc.empty) {
							t.Errorf("unexpected hook input or persistence ordering: %q %q", key, response)
						}
						return "replacement"
					})
					mgr.SetHooks(hooks)
				}
				response, err := mgr.Dispatch(ctx, t.Name(), "alice", "hello")
				want := body
				if tc.fail || tc.cancel || tc.deadline {
					want = checkpointSaveWarning + want
				}
				if tc.stateless {
					want = statelessWarning + want
				}
				if err != nil || response != want {
					t.Fatalf("response=%q error=%v; want %q", response, err, want)
				}
				if len(runner.calls) != 1 || len(runner.textCalls) != 0 || hookCalls != btoi(hooked) || store.saveCalls != btoi(!tc.nilStore && !tc.stateless && !tc.empty) {
					t.Fatal("unexpected runner, hook, or save invocation count")
				}
				if snap := store.snapshots[t.Name()]; snap != nil {
					for _, message := range snap.Messages {
						if message.Content != nil && strings.Contains(message.Content.String(), "Warning:") {
							t.Fatal("warning persisted in history")
						}
					}
				}
			})
		}
	}
}

func btoi(value bool) int {
	if value {
		return 1
	}
	return 0
}

type saveOutcomeLogger struct {
	calls int
	err   error
}

func (l *saveOutcomeLogger) Log(_ string, _ int, _ []agentctx.StrategicMessage) error {
	l.calls++
	return l.err
}

//nolint:gocognit // table checks independent snapshot and transcript failure combinations.
func TestDispatchCheckpointTranscriptOutcomes(t *testing.T) {
	t.Parallel()
	for _, saveFails := range []bool{false, true} {
		for _, logFails := range []bool{false, true} {
			t.Run(fmt.Sprintf("saveFails=%t/logFails=%t", saveFails, logFails), func(t *testing.T) {
				t.Parallel()
				store := newMockStore()
				logger := &saveOutcomeLogger{}
				if saveFails {
					store.saveErr = errors.New("snapshot unavailable")
				}
				if logFails {
					logger.err = errors.New("transcript unavailable")
				}
				mgr := NewSessionManager(&mockRunner{response: checkpointTestReply}, store, "model")
				mgr.SetLogger(logger)
				response, err := mgr.Dispatch(context.Background(), t.Name(), "", "hello")
				want := checkpointTestReply
				if saveFails {
					want = checkpointSaveWarning + want
				}
				if err != nil || response != want || logger.calls != 1 || store.saveCalls != 1 {
					t.Fatalf("response=%q error=%v logs=%d saves=%d", response, err, logger.calls, store.saveCalls)
				}
			})
		}
	}
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
