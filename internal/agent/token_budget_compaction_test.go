//nolint:testpackage // token-budget helpers are package-private implementation details.
package agent

import (
	"context"
	"sync"
	"testing"
	"time"

	agentctx "github.com/allthingscode/gobot/internal/context"
)

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
			mgr := &SessionManager{tokenBudget: tt.budget, runner: &mockRunner{response: "summary"}}

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

	mgr.updateTokenBudget(context.Background(), testSess, messages, store)

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
}

func TestSessionManager_CompactSessionAsyncPersistsSummaryAndMetadata(t *testing.T) {
	t.Parallel()
	store := &tokenBudgetStore{
		tokens:   200,
		snapshot: tokenBudgetSnapshot(42, []string{"turn 1", "turn 2", "turn 3", "turn 4", "turn 5"}),
	}
	mgr := &SessionManager{
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
	assertMessage(t, saves[0].messages[0], agentctx.RoleSystem, "compacted summary", "summary")
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
