//nolint:testpackage // token-budget helpers are package-private implementation details.
package agent

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	agentctx "github.com/allthingscode/gobot/internal/context"
)

const compactionTestSummary = "summary"
const compactionTestReply = "reply"

type tokenUpdateCall struct {
	tokens      int
	compactedAt *time.Time
}

type tokenSnapshotSave struct {
	iteration int
	messages  []agentctx.StrategicMessage
}

type tokenBudgetStore struct {
	mu          sync.Mutex
	snapshot    *agentctx.ThreadSnapshot
	tokens      int
	compactedAt *time.Time
	updates     []tokenUpdateCall
	saves       []tokenSnapshotSave

	loadStarted chan struct{}
	unblockLoad chan struct{}
	loadOnce    sync.Once
}

func (s *tokenBudgetStore) LoadLatest(_ context.Context, _ string) (*agentctx.ThreadSnapshot, error) {
	if s.loadStarted != nil {
		s.loadOnce.Do(func() { close(s.loadStarted) })
	}
	if s.unblockLoad != nil {
		<-s.unblockLoad
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if s.snapshot == nil {
		return nil, nil
	}
	return &agentctx.ThreadSnapshot{
		Iteration: s.snapshot.Iteration,
		Messages:  append([]agentctx.StrategicMessage(nil), s.snapshot.Messages...),
		Model:     s.snapshot.Model,
		Metadata:  s.snapshot.Metadata,
	}, nil
}

func (s *tokenBudgetStore) SaveSnapshot(_ context.Context, _ string, iteration int, messages []agentctx.StrategicMessage) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	copied := append([]agentctx.StrategicMessage(nil), messages...)
	s.saves = append(s.saves, tokenSnapshotSave{iteration: iteration, messages: copied})
	s.snapshot = &agentctx.ThreadSnapshot{
		Iteration: iteration,
		Messages:  copied,
		Model:     "mock",
		Metadata:  map[string]any{"estimated_tokens": s.tokens},
	}
	return true, nil
}

func (s *tokenBudgetStore) CreateThread(_ context.Context, _, _ string, _ map[string]any) error {
	return nil
}

func (s *tokenBudgetStore) UpdateSessionTokens(_ context.Context, _ string, tokens int, compactedAt *time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.tokens = tokens
	s.compactedAt = compactedAt
	s.updates = append(s.updates, tokenUpdateCall{tokens: tokens, compactedAt: compactedAt})
	return nil
}

func (s *tokenBudgetStore) GetSessionTokens(_ context.Context, _ string) (int, *time.Time, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.tokens, s.compactedAt, nil
}

func (s *tokenBudgetStore) updateCalls() []tokenUpdateCall {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]tokenUpdateCall(nil), s.updates...)
}

func (s *tokenBudgetStore) saveCalls() []tokenSnapshotSave {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]tokenSnapshotSave(nil), s.saves...)
}

func TestSessionManager_UpdateTokenBudgetThresholds(t *testing.T) {
	t.Parallel()

	messages := []agentctx.StrategicMessage{
		tokenBudgetMessage(agentctx.RoleUser, "one two three four"),
	}
	estimated := estimateTokensForMessages(messages)

	tests := []struct {
		name         string
		budget       int
		store        *tokenBudgetStore
		wantUpdates  int
		wantTokens   int
		wantCompacts bool
	}{
		{
			name:        "disabled budget skips persistence",
			budget:      0,
			store:       &tokenBudgetStore{tokens: 12},
			wantUpdates: 0,
			wantTokens:  12,
		},
		{
			name:        "below threshold accumulates existing total",
			budget:      30,
			store:       &tokenBudgetStore{tokens: 10},
			wantUpdates: 1,
			wantTokens:  10 + estimated,
		},
		{
			name:        "at threshold persists without compaction",
			budget:      10 + estimated,
			store:       &tokenBudgetStore{tokens: 10},
			wantUpdates: 1,
			wantTokens:  10 + estimated,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			mgr := &SessionManager{tokenBudget: tt.budget, runner: &mockRunner{response: compactionTestSummary}}

			mgr.updateTokenBudget(context.Background(), testSess, messages, tt.store)

			updates := tt.store.updateCalls()
			if len(updates) != tt.wantUpdates {
				t.Fatalf("UpdateSessionTokens calls = %d, want %d", len(updates), tt.wantUpdates)
			}
			if tt.store.tokens != tt.wantTokens {
				t.Fatalf("stored tokens = %d, want %d", tt.store.tokens, tt.wantTokens)
			}
			if len(tt.store.saveCalls()) != 0 {
				t.Fatal("unexpected compaction snapshot save")
			}
		})
	}
}

func TestSessionManager_UpdateTokenBudgetNilStore(t *testing.T) {
	t.Parallel()
	mgr := &SessionManager{tokenBudget: 1}

	mgr.updateTokenBudget(context.Background(), testSess, []agentctx.StrategicMessage{
		tokenBudgetMessage(agentctx.RoleUser, "hello world"),
	}, nil)
}

func TestSessionManager_UpdateTokenBudgetPersistsTotalBeforeAsyncCompaction(t *testing.T) {
	t.Parallel()
	messages := []agentctx.StrategicMessage{
		tokenBudgetMessage(agentctx.RoleUser, "one two three four"),
	}
	initialTokens := 10
	accumulatedTokens := initialTokens + estimateTokensForMessages(messages)
	store := &tokenBudgetStore{
		tokens:      initialTokens,
		snapshot:    tokenBudgetSnapshot(7, []string{"old 1", "old 2", "recent 1", "recent 2"}),
		loadStarted: make(chan struct{}),
		unblockLoad: make(chan struct{}),
	}
	mgr := &SessionManager{
		tokenBudget:  accumulatedTokens - 1,
		summaryTurns: 2,
		runner:       &mockRunner{response: "summary after trigger"},
	}

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(func() {
		cancel()
		releaseCompactionBarrier(store.unblockLoad)
		waitForCondition(t, "background compaction cleanup", func() bool {
			_, exists := GetLockMetrics()[t.Name()]
			return !exists
		})
	})
	mgr.updateTokenBudget(ctx, t.Name(), messages, store)

	waitForClosed(t, store.loadStarted, "background compaction to load snapshot")
	updates := store.updateCalls()
	if len(updates) != 1 {
		t.Fatalf("updates before compaction = %d, want 1", len(updates))
	}
	if updates[0].tokens != accumulatedTokens {
		t.Fatalf("pre-compaction tokens = %d, want %d", updates[0].tokens, accumulatedTokens)
	}
	if updates[0].compactedAt != nil {
		t.Fatal("pre-compaction update should not set compacted timestamp")
	}

	close(store.unblockLoad)
	waitForCondition(t, "compaction to save snapshot", func() bool {
		return len(store.saveCalls()) == 1
	})
	waitForCondition(t, "compaction to release its lock", func() bool {
		_, exists := GetLockMetrics()[t.Name()]
		return !exists
	})
}

func TestSessionManager_CompactSessionAsyncPersistsSummaryAndMetadata(t *testing.T) {
	t.Parallel()
	store := &tokenBudgetStore{
		tokens:   200,
		snapshot: tokenBudgetSnapshot(42, []string{"turn 1", "turn 2", "turn 3", "turn 4", "turn 5"}),
	}
	mgr := &SessionManager{
		tokenBudget:  100,
		summaryTurns: 2,
		runner:       &mockRunner{response: "compacted summary"},
	}

	mgr.compactSessionAsync(context.Background(), testSess, store)

	saves := store.saveCalls()
	assertCompactedSnapshot(t, saves)

	updates := store.updateCalls()
	assertCompactedTokenUpdate(t, updates, saves[0].messages)
}

func assertCompactedSnapshot(t *testing.T, saves []tokenSnapshotSave) {
	t.Helper()
	if len(saves) != 1 {
		t.Fatalf("SaveSnapshot calls = %d, want 1", len(saves))
	}
	if saves[0].iteration != 42 {
		t.Fatalf("saved iteration = %d, want 42", saves[0].iteration)
	}
	if len(saves[0].messages) != 3 {
		t.Fatalf("saved messages = %d, want 3", len(saves[0].messages))
	}
	assertMessage(t, saves[0].messages[0], agentctx.RoleSystem, "compacted summary", compactionTestSummary)
	assertMessage(t, saves[0].messages[1], agentctx.RoleAssistant, "turn 4", "first kept")
	assertMessage(t, saves[0].messages[2], agentctx.RoleUser, "turn 5", "second kept")
}

func assertCompactedTokenUpdate(t *testing.T, updates []tokenUpdateCall, messages []agentctx.StrategicMessage) {
	t.Helper()
	if len(updates) != 1 {
		t.Fatalf("UpdateSessionTokens calls = %d, want 1", len(updates))
	}
	wantTokens := estimateTokensForMessages(messages)
	if updates[0].tokens != wantTokens {
		t.Fatalf("compacted tokens = %d, want %d", updates[0].tokens, wantTokens)
	}
	if updates[0].compactedAt == nil {
		t.Fatal("compacted token update should include timestamp")
	}
}

func assertMessage(t *testing.T, msg agentctx.StrategicMessage, wantRole agentctx.MessageRole, wantContent, label string) {
	t.Helper()
	if msg.Role != wantRole {
		t.Fatalf("%s role = %s, want %s", label, msg.Role, wantRole)
	}
	if got := msg.Content.String(); got != wantContent {
		t.Fatalf("%s content = %q, want %q", label, got, wantContent)
	}
}

func tokenBudgetSnapshot(iteration int, contents []string) *agentctx.ThreadSnapshot {
	messages := make([]agentctx.StrategicMessage, 0, len(contents))
	for i, content := range contents {
		role := agentctx.RoleUser
		if i%2 == 1 {
			role = agentctx.RoleAssistant
		}
		messages = append(messages, tokenBudgetMessage(role, content))
	}
	return &agentctx.ThreadSnapshot{
		Iteration: iteration,
		Messages:  messages,
		Model:     "mock",
		Metadata:  map[string]any{},
	}
}

func tokenBudgetMessage(role agentctx.MessageRole, content string) agentctx.StrategicMessage {
	return agentctx.StrategicMessage{
		Role:    role,
		Content: &agentctx.MessageContent{Str: &content},
	}
}

func waitForClosed(t *testing.T, ch <-chan struct{}, description string) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(2 * time.Second):
		t.Fatalf("timed out waiting for %s", description)
	}
}

func waitForCondition(t *testing.T, description string, condition func() bool) {
	t.Helper()
	deadline := time.After(2 * time.Second)
	tick := time.NewTicker(time.Millisecond)
	defer tick.Stop()
	for {
		if condition() {
			return
		}
		select {
		case <-deadline:
			t.Fatalf("timed out waiting for %s", description)
		case <-tick.C:
		}
	}
}

// compactionStore decorates real SQLite with controlled failures and barriers.
type compactionStore struct {
	CheckpointStore
	load  func(context.Context, string) (*agentctx.ThreadSnapshot, error)
	save  func(context.Context, string, int, []agentctx.StrategicMessage) (bool, error)
	read  func(context.Context, string) (int, *time.Time, error)
	write func(context.Context, string, int, *time.Time) error
}

func (s *compactionStore) LoadLatest(ctx context.Context, key string) (*agentctx.ThreadSnapshot, error) {
	if s.load != nil {
		return s.load(ctx, key)
	}
	return s.CheckpointStore.LoadLatest(ctx, key)
}
func (s *compactionStore) SaveSnapshot(ctx context.Context, key string, iteration int, messages []agentctx.StrategicMessage) (bool, error) {
	if s.save != nil {
		return s.save(ctx, key, iteration, messages)
	}
	return s.CheckpointStore.SaveSnapshot(ctx, key, iteration, messages)
}
func (s *compactionStore) GetSessionTokens(ctx context.Context, key string) (int, *time.Time, error) {
	if s.read != nil {
		return s.read(ctx, key)
	}
	return s.CheckpointStore.GetSessionTokens(ctx, key)
}
func (s *compactionStore) UpdateSessionTokens(ctx context.Context, key string, tokens int, at *time.Time) error {
	if s.write != nil {
		return s.write(ctx, key, tokens, at)
	}
	return s.CheckpointStore.UpdateSessionTokens(ctx, key, tokens, at)
}

type compactionRunner struct {
	run  func(context.Context, string, []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error)
	text func(context.Context, string, string) (string, error)
}

func (r *compactionRunner) Run(ctx context.Context, key, _ string, messages []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error) {
	if r.run != nil {
		return r.run(ctx, key, messages)
	}
	return compactionTestReply, append(messages, tokenBudgetMessage(agentctx.RoleAssistant, compactionTestReply)), nil
}
func (r *compactionRunner) RunText(ctx context.Context, key, prompt, _ string) (string, error) {
	if r.text != nil {
		return r.text(ctx, key, prompt)
	}
	return compactionTestSummary, nil
}

func sqliteCompactionFixture(t *testing.T) (*compactionStore, *SessionManager) {
	t.Helper()
	dir := t.TempDir()
	store, err := agentctx.GetCheckpointManager(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { agentctx.EvictCheckpointManagerForTest(dir) })
	seedCompactionSession(t, store, t.Name())
	wrapped := &compactionStore{CheckpointStore: store}
	mgr := NewSessionManager(&compactionRunner{}, wrapped, "mock")
	mgr.SetTokenBudget(100)
	mgr.SetSummaryTurns(2)
	return wrapped, mgr
}
func seedCompactionSession(t *testing.T, store CheckpointStore, key string) {
	t.Helper()
	ctx := context.Background()
	if err := store.CreateThread(ctx, key, "mock", nil); err != nil {
		t.Fatal(err)
	}
	messages := tokenBudgetSnapshot(1, []string{"old one", "old two", "recent one", "recent two"}).Messages
	if saved, err := store.SaveSnapshot(ctx, key, 1, messages); err != nil || !saved {
		t.Fatalf("seed save: %v %v", saved, err)
	}
	if err := store.UpdateSessionTokens(ctx, key, 1000, nil); err != nil {
		t.Fatal(err)
	}
}
func startCompaction(t *testing.T, mgr *SessionManager, key string, store CheckpointStore) <-chan struct{} {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { defer close(done); mgr.compactSessionAsync(ctx, key, store) }()
	t.Cleanup(func() { cancel(); waitForClosed(t, done, "worker cleanup") })
	return done
}
func startCompactionDispatch(t *testing.T, mgr *SessionManager, key string) <-chan error {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	result := make(chan error, 1)
	done := make(chan struct{})
	go func() { defer close(done); _, err := mgr.Dispatch(ctx, key, "alice", "newest user"); result <- err }()
	t.Cleanup(func() { cancel(); waitForClosed(t, done, "dispatch cleanup") })
	return result
}
func awaitCompactionDispatch(t *testing.T, result <-chan error) {
	t.Helper()
	select {
	case err := <-result:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("dispatch timed out")
	}
}
func releaseCompactionBarrier(release chan struct{}) {
	select {
	case <-release:
	default:
		close(release)
	}
}
func assertCompactionLatest(t *testing.T, store CheckpointStore, iteration int, contents []string) {
	t.Helper()
	snap, err := store.LoadLatest(context.Background(), t.Name())
	if err != nil || snap == nil {
		t.Fatalf("latest: %v %v", snap, err)
	}
	if snap.Iteration != iteration || len(snap.Messages) != len(contents) {
		t.Fatalf("latest = %#v; expected iteration %d with %d messages", snap, iteration, len(contents))
	}
	for i, want := range contents {
		if snap.Messages[i].Content.String() != want {
			t.Fatalf("message %d = %q, want %q", i, snap.Messages[i].Content.String(), want)
		}
	}
}
func assertCompactionLockReleased(t *testing.T) {
	t.Helper()
	if _, exists := GetLockMetrics()[t.Name()]; exists {
		t.Fatal("compaction leaked lock reference")
	}
}

func TestCompactionSQLiteWorkerFirstAndIndependentSessions(t *testing.T) {
	t.Parallel()
	store, mgr := sqliteCompactionFixture(t)
	entered, release := make(chan struct{}), make(chan struct{})
	runner := &compactionRunner{text: func(ctx context.Context, key, _ string) (string, error) {
		if key == t.Name() {
			close(entered)
			select {
			case <-release:
			case <-ctx.Done():
				return "", ctx.Err()
			}
		}
		return compactionTestSummary, nil
	}}
	mgr.runner = runner
	worker := startCompaction(t, mgr, t.Name(), store)
	t.Cleanup(func() { releaseCompactionBarrier(release) })
	waitForClosed(t, entered, "summary holding session lock")
	dispatch := startCompactionDispatch(t, mgr, t.Name())
	waitForCondition(t, "dispatch waiting on compaction lock", func() bool { return GetLockMetrics()[t.Name()].WaitCount >= 1 })
	other := t.Name() + "/independent"
	seedCompactionSession(t, store.CheckpointStore, other)
	otherManager := NewSessionManager(runner, nil, "mock")
	otherManager.SetTokenBudget(100)
	otherManager.SetSummaryTurns(2)
	otherManager.SetCheckpointStoreProvider(func(string) (CheckpointStore, error) { return store, nil })
	otherHooks := &Hooks{}
	otherHooks.RegisterPostDispatch(func(_ context.Context, key, response string) string {
		waitForCondition(t, "independent automatic worker queued", func() bool { return GetLockMetrics()[key].WaitCount >= 1 })
		return response
	})
	otherManager.SetHooks(otherHooks)
	awaitCompactionDispatch(t, startCompactionDispatch(t, otherManager, other))
	waitForClosed(t, startCompaction(t, otherManager, other, store), "unrelated compaction")
	waitForCondition(t, "independent workers finished", func() bool {
		_, exists := GetLockMetrics()[other]
		return !exists
	})
	otherSnap, err := store.LoadLatest(context.Background(), other)
	if err != nil || otherSnap.Messages[0].Content.String() != compactionTestSummary {
		t.Fatalf("independent session did not compact: %v", err)
	}
	close(release)
	waitForClosed(t, worker, "worker-first publication")
	awaitCompactionDispatch(t, dispatch)
	assertCompactionLatest(t, store, 2, []string{compactionTestSummary, "recent one", "recent two", "newest user", compactionTestReply})
	assertCompactionLockReleased(t)
}

func TestCompactionSQLiteDispatchFirstAndQueuedWorkers(t *testing.T) {
	t.Parallel()
	store, mgr := sqliteCompactionFixture(t)
	entered, release := make(chan struct{}), make(chan struct{})
	prompts := make(chan string, 3)
	mgr.runner = &compactionRunner{
		run: func(ctx context.Context, _ string, messages []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error) {
			close(entered)
			select {
			case <-release:
			case <-ctx.Done():
				return "", nil, ctx.Err()
			}
			return compactionTestReply, append(messages, tokenBudgetMessage(agentctx.RoleAssistant, compactionTestReply)), nil
		},
		text: func(_ context.Context, _, prompt string) (string, error) {
			prompts <- prompt
			return compactionTestSummary, nil
		},
	}
	hooks := &Hooks{}
	hooks.RegisterPostDispatch(func(_ context.Context, key, response string) string {
		waitForCondition(t, "automatic worker queued after save", func() bool { return GetLockMetrics()[key].WaitCount >= 3 })
		return response
	})
	mgr.SetHooks(hooks)
	dispatch := startCompactionDispatch(t, mgr, t.Name())
	t.Cleanup(func() { releaseCompactionBarrier(release) })
	waitForClosed(t, entered, "dispatch holding lock")
	workers := []<-chan struct{}{startCompaction(t, mgr, t.Name(), store), startCompaction(t, mgr, t.Name(), store)}
	waitForCondition(t, "both queued workers", func() bool { return GetLockMetrics()[t.Name()].WaitCount >= 2 })
	close(release)
	awaitCompactionDispatch(t, dispatch)
	for _, done := range workers {
		waitForClosed(t, done, "queued worker")
	}
	mgr.compactSessionAsync(context.Background(), t.Name(), store)
	waitForCondition(t, "all queued workers to release references", func() bool {
		_, exists := GetLockMetrics()[t.Name()]
		return !exists
	})
	if len(prompts) != 1 {
		t.Fatalf("summaries = %d, want one after token recheck", len(prompts))
	}
	if prompt := <-prompts; !strings.Contains(prompt, "recent two") {
		t.Fatal("worker summarized stale iteration-one prefix")
	}
	assertCompactionLatest(t, store, 2, []string{compactionTestSummary, "newest user", compactionTestReply})
	tokens, at, err := store.GetSessionTokens(context.Background(), t.Name())
	if err != nil || at == nil || tokens != estimateTokensForMessages(tokenBudgetSnapshot(2, []string{compactionTestSummary, "newest user", compactionTestReply}).Messages) {
		t.Fatalf("metadata: %d %v %v", tokens, at, err)
	}
	assertCompactionLockReleased(t)
}

func TestCompactionSQLiteSaveBeforeTrigger(t *testing.T) {
	t.Parallel()
	store, mgr := sqliteCompactionFixture(t)
	entered, release := make(chan struct{}), make(chan struct{})
	published := make(chan struct{})
	var reads atomic.Int32
	store.read = func(ctx context.Context, key string) (int, *time.Time, error) {
		reads.Add(1)
		return store.CheckpointStore.GetSessionTokens(ctx, key)
	}
	store.save = func(ctx context.Context, key string, iteration int, messages []agentctx.StrategicMessage) (bool, error) {
		if iteration == 2 && len(messages) == 6 {
			close(entered)
			select {
			case <-release:
			case <-ctx.Done():
				return false, ctx.Err()
			}
		}
		return store.CheckpointStore.SaveSnapshot(ctx, key, iteration, messages)
	}
	store.write = func(ctx context.Context, key string, tokens int, at *time.Time) error {
		err := store.CheckpointStore.UpdateSessionTokens(ctx, key, tokens, at)
		if at != nil {
			close(published)
		}
		return err
	}
	dispatch := startCompactionDispatch(t, mgr, t.Name())
	t.Cleanup(func() { releaseCompactionBarrier(release) })
	waitForClosed(t, entered, "triggering save")
	if reads.Load() != 0 {
		t.Fatal("token accumulation or worker started before triggering save acknowledged")
	}
	close(release)
	awaitCompactionDispatch(t, dispatch)
	waitForClosed(t, published, "automatic compaction publication")
	mgr.compactSessionAsync(context.Background(), t.Name(), store)
	assertCompactionLatest(t, store, 2, []string{compactionTestSummary, "newest user", compactionTestReply})
	assertCompactionLockReleased(t)
}

//nolint:paralleltest,gocognit,cyclop // synchronous failure matrix captures global slog and checks durable state separately from metadata.
func TestCompactionSQLitePublicationFailures(t *testing.T) {
	oldLogger := slog.Default()
	var logs bytes.Buffer
	slog.SetDefault(slog.New(slog.NewTextHandler(&logs, nil)))
	t.Cleanup(func() { slog.SetDefault(oldLogger) })
	cases := []struct {
		name      string
		configure func(*compactionStore, *SessionManager, context.CancelFunc)
		durable   bool
	}{
		{"token read", func(s *compactionStore, _ *SessionManager, _ context.CancelFunc) {
			s.read = func(context.Context, string) (int, *time.Time, error) { return 0, nil, errors.New("read unavailable") }
		}, false},
		{"load", func(s *compactionStore, _ *SessionManager, _ context.CancelFunc) {
			s.load = func(context.Context, string) (*agentctx.ThreadSnapshot, error) {
				return nil, errors.New("load unavailable")
			}
		}, false},
		{compactionTestSummary, func(_ *compactionStore, m *SessionManager, _ context.CancelFunc) {
			m.runner = &compactionRunner{text: func(context.Context, string, string) (string, error) { return "", errors.New("model unavailable") }}
		}, false},
		{"cancel before model", func(s *compactionStore, _ *SessionManager, cancel context.CancelFunc) {
			s.load = func(ctx context.Context, key string) (*agentctx.ThreadSnapshot, error) {
				snap, err := s.CheckpointStore.LoadLatest(ctx, key)
				cancel()
				return snap, err
			}
		}, false},
		{"cancel during model", func(_ *compactionStore, m *SessionManager, cancel context.CancelFunc) {
			m.runner = &compactionRunner{text: func(ctx context.Context, _, _ string) (string, error) { cancel(); return "", ctx.Err() }}
		}, false},
		{"cancel before save ignored by runner", func(_ *compactionStore, m *SessionManager, cancel context.CancelFunc) {
			m.runner = &compactionRunner{text: func(context.Context, string, string) (string, error) { cancel(); return compactionTestSummary, nil }}
		}, false},
		{"save error", func(s *compactionStore, _ *SessionManager, _ context.CancelFunc) {
			s.save = func(context.Context, string, int, []agentctx.StrategicMessage) (bool, error) {
				return false, errors.New("save unavailable")
			}
		}, false},
		{"save not acknowledged", func(s *compactionStore, _ *SessionManager, _ context.CancelFunc) {
			s.save = func(context.Context, string, int, []agentctx.StrategicMessage) (bool, error) { return false, nil }
		}, false},
		{"metadata error", func(s *compactionStore, _ *SessionManager, _ context.CancelFunc) {
			s.write = func(context.Context, string, int, *time.Time) error { return errors.New("metadata unavailable") }
		}, true},
		{"cancel after save", func(s *compactionStore, _ *SessionManager, cancel context.CancelFunc) {
			s.save = func(ctx context.Context, key string, iteration int, messages []agentctx.StrategicMessage) (bool, error) {
				saved, err := s.CheckpointStore.SaveSnapshot(ctx, key, iteration, messages)
				cancel()
				return saved, err
			}
		}, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			logs.Reset()
			store, mgr := sqliteCompactionFixture(t)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			tc.configure(store, mgr, cancel)
			mgr.compactSessionAsync(ctx, t.Name(), store)
			want := []string{"old one", "old two", "recent one", "recent two"}
			if tc.durable {
				want = []string{compactionTestSummary, "recent one", "recent two"}
			}
			assertCompactionLatest(t, store.CheckpointStore, 1, want)
			tokens, at, err := store.CheckpointStore.GetSessionTokens(context.Background(), t.Name())
			if err != nil || tokens != 1000 || at != nil {
				t.Fatalf("failure published metadata: %d %v %v", tokens, at, err)
			}
			if strings.Contains(logs.String(), "per-session compaction complete") {
				t.Fatal("failure logged completion")
			}
			if tc.durable && !strings.Contains(logs.String(), "snapshot persisted but token metadata update failed") {
				t.Fatal("missing partial-publication warning")
			}
			assertCompactionLockReleased(t)
			assertCompactionRetry(t, store, mgr)
		})
	}
}

// assertCompactionRetry verifies recovery against the latest durable snapshot.
func assertCompactionRetry(t *testing.T, store *compactionStore, mgr *SessionManager) {
	t.Helper()
	store.load, store.save, store.read, store.write = nil, nil, nil, nil
	mgr.runner = &compactionRunner{}
	mgr.compactSessionAsync(context.Background(), t.Name(), store)
	assertCompactionLatest(t, store, 1, []string{compactionTestSummary, "recent one", "recent two"})
	snap, err := store.LoadLatest(context.Background(), t.Name())
	if err != nil {
		t.Fatal(err)
	}
	tokens, at, err := store.GetSessionTokens(context.Background(), t.Name())
	if err != nil || at == nil || tokens != estimateTokensForMessages(snap.Messages) {
		t.Fatalf("retry metadata: %d %v %v", tokens, at, err)
	}
}

func TestCompactionLockCancellationAndTimeout(t *testing.T) {
	t.Parallel()
	for _, cancelled := range []bool{true, false} {
		t.Run(fmt.Sprintf("cancelled=%t", cancelled), func(t *testing.T) {
			t.Parallel()
			store, mgr := sqliteCompactionFixture(t)
			lock := acquireLock(t.Name(), time.Millisecond)
			if err := lock.Lock(context.Background()); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			if cancelled {
				cancel()
			}
			mgr.compactSessionAsync(ctx, t.Name(), store)
			allLocksMu.Lock()
			refs := lock.refCount
			allLocksMu.Unlock()
			lock.Unlock()
			lock.release()
			if refs != 1 {
				t.Fatalf("waiting worker leaked reference: %d", refs)
			}
			assertCompactionLatest(t, store, 1, []string{"old one", "old two", "recent one", "recent two"})
			assertCompactionLockReleased(t)
		})
	}
}

func TestTokenBudgetMetadataErrorsDoNotSchedule(t *testing.T) {
	t.Parallel()
	for _, readFails := range []bool{true, false} {
		t.Run(fmt.Sprintf("readFails=%t", readFails), func(t *testing.T) {
			t.Parallel()
			store, mgr := sqliteCompactionFixture(t)
			if readFails {
				store.read = func(context.Context, string) (int, *time.Time, error) { return 0, nil, errors.New("tokens unreadable") }
			} else {
				store.write = func(context.Context, string, int, *time.Time) error { return errors.New("tokens unwritable") }
			}
			mgr.runner = &compactionRunner{text: func(context.Context, string, string) (string, error) {
				t.Error("scheduled worker on unconfirmed token metadata")
				return compactionTestSummary, nil
			}}
			mgr.updateTokenBudget(context.Background(), t.Name(), tokenBudgetSnapshot(1, []string{"turn"}).Messages, store)
			tokens, at, err := store.CheckpointStore.GetSessionTokens(context.Background(), t.Name())
			if err != nil || tokens != 1000 || at != nil {
				t.Fatalf("unconfirmed update changed metadata: %d %v %v", tokens, at, err)
			}
			assertCompactionLockReleased(t)
		})
	}
}

func TestCompactionQueuedWorkerStillAboveBudgetUsesLatest(t *testing.T) {
	t.Parallel()
	store, mgr := sqliteCompactionFixture(t)
	mgr.SetTokenBudget(1)
	mgr.SetSummaryTurns(1)
	entered, release := make(chan struct{}), make(chan struct{})
	prompts := make(chan string, 2)
	mgr.runner = &compactionRunner{text: func(ctx context.Context, _, prompt string) (string, error) {
		prompts <- prompt
		if len(prompts) == 1 {
			close(entered)
			select {
			case <-release:
			case <-ctx.Done():
				return "", ctx.Err()
			}
		}
		return compactionTestSummary, nil
	}}
	first := startCompaction(t, mgr, t.Name(), store)
	t.Cleanup(func() { releaseCompactionBarrier(release) })
	waitForClosed(t, entered, "first summary")
	second := startCompaction(t, mgr, t.Name(), store)
	waitForCondition(t, "second worker queued", func() bool { return GetLockMetrics()[t.Name()].WaitCount >= 1 })
	close(release)
	waitForClosed(t, first, "first publication")
	waitForClosed(t, second, "second publication")
	if len(prompts) != 2 {
		t.Fatalf("summaries = %d", len(prompts))
	}
	<-prompts
	if prompt := <-prompts; !strings.Contains(prompt, "system: summary") || strings.Contains(prompt, "old one") {
		t.Fatalf("second worker captured stale history: %s", prompt)
	}
	assertCompactionLatest(t, store, 1, []string{compactionTestSummary, "recent two"})
	assertCompactionLockReleased(t)
}

func TestCompactionEligibilitySkips(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name             string
		budget, count    int
		nilStore, cancel bool
	}{
		{"disabled", 0, 4, false, false},
		{"nil store", 100, 4, true, false},
		{"cancelled", 100, 4, false, true},
		{"no snapshot", 100, -1, false, false},
		{"empty snapshot", 100, 0, false, false},
		{"short history", 100, 2, false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			store, mgr := sqliteCompactionFixture(t)
			mgr.tokenBudget = tc.budget
			store.load = func(context.Context, string) (*agentctx.ThreadSnapshot, error) {
				if tc.count < 0 {
					return nil, nil
				}
				return &agentctx.ThreadSnapshot{Iteration: 1, Messages: make([]agentctx.StrategicMessage, tc.count)}, nil
			}
			mgr.runner = &compactionRunner{text: func(context.Context, string, string) (string, error) {
				t.Error("ineligible worker called model")
				return "", nil
			}}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			if tc.cancel {
				cancel()
			}
			var active CheckpointStore = store
			if tc.nilStore {
				active = nil
			}
			mgr.compactSessionAsync(ctx, t.Name(), active)
			tokens, at, err := store.CheckpointStore.GetSessionTokens(context.Background(), t.Name())
			if err != nil || tokens != 1000 || at != nil {
				t.Fatal("ineligible worker changed metadata")
			}
			assertCompactionLockReleased(t)
		})
	}
}

func TestDispatchAcknowledgedSaveWithCancelledContextDoesNotAccumulate(t *testing.T) {
	t.Parallel()
	store, mgr := sqliteCompactionFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	store.save = func(ctx context.Context, key string, iteration int, messages []agentctx.StrategicMessage) (bool, error) {
		saved, err := store.CheckpointStore.SaveSnapshot(ctx, key, iteration, messages)
		cancel()
		return saved, err
	}
	response, err := mgr.Dispatch(ctx, t.Name(), "alice", "newest user")
	if err != nil || response != compactionTestReply {
		t.Fatalf("response=%q error=%v", response, err)
	}
	tokens, at, err := store.GetSessionTokens(context.Background(), t.Name())
	if err != nil || tokens != 1000 || at != nil {
		t.Fatalf("cancelled turn changed tokens: %d %v %v", tokens, at, err)
	}
	assertCompactionLatest(t, store, 2, []string{"old one", "old two", "recent one", "recent two", "newest user", compactionTestReply})
	assertCompactionLockReleased(t)
}
