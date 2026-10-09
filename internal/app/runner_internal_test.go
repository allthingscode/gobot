//nolint:testpackage // intentionally uses unexported helpers from main package
package app

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"golang.org/x/time/rate"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/memory"
	"github.com/allthingscode/gobot/internal/provider"
	"github.com/allthingscode/gobot/internal/resilience"
)

const (
	testSess   = "sess"
	testUser   = "user"
	testModel  = "test-model"
	testResult = "result"
	basePrompt = "base prompt"
)

func TestRunner_BuildSystemPrompt_NoMemStore(t *testing.T) {
	t.Parallel()
	r := &AgentRunner{
		SystemPrompt: basePrompt,
	}
	got := r.buildSystemPrompt(context.Background(), testSess, nil, nil)
	if got != basePrompt {
		t.Errorf("got %q, want %q", got, basePrompt)
	}
}

func TestRunner_BuildSystemPrompt_WithMemStore(t *testing.T) {
	t.Parallel()
	r := &AgentRunner{
		SystemPrompt: basePrompt,
		Cfg:          &config.Config{},
	}
	userMsg := "test message"
	messages := []agentctx.StrategicMessage{
		{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: &userMsg}},
	}

	// With nil memStore, should return base prompt
	got := r.buildSystemPrompt(context.Background(), testSess, messages, nil)
	if got != basePrompt {
		t.Errorf("got %q, want %q", got, basePrompt)
	}
}

func TestRunner_GetRagBlock_Empty(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	memStore, err := memory.NewMemoryStore(tmpDir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = memStore.Close()
	}()

	r := &AgentRunner{
		Cfg: &config.Config{},
	}
	// With empty memStore, should return empty block
	got := r.getRagBlock(context.Background(), testSess, "user text", memStore)
	if got != "" {
		t.Errorf("expected empty RAG block for empty memStore, got %q", got)
	}
}

func TestRunner_FtsSearch(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	memStore, err := memory.NewMemoryStore(tmpDir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = memStore.Close()
	}()

	// Index some content
	err = memStore.Index("session:sess", "USER: how are you?")
	if err != nil {
		t.Fatal(err)
	}

	r := &AgentRunner{}
	results := r.ftsSearch(context.Background(), "how are you", testSess, memStore)
	if len(results) == 0 {
		t.Error("expected FTS results, got none")
	}
}

func TestRunner_ExecuteToolInner(t *testing.T) {
	t.Parallel()
	r := &AgentRunner{}
	r.SetTools([]Tool{&mockTool{name: "test_tool"}})

	ctx := context.Background()

	// Case 1: Success
	got, err := r.executeToolInner(ctx, testSess, testUser, "test_tool", nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != testResult {
		t.Errorf("got %q, want %q", got, testResult)
	}

	// Case 2: Unknown tool
	_, err = r.executeToolInner(ctx, testSess, testUser, "unknown", nil)
	if err == nil {
		t.Error("expected error for unknown tool")
	}
}

func TestAgentRunner_Setters(t *testing.T) {
	t.Parallel()
	r := &AgentRunner{}

	r.SetTracer(nil)
	r.SetIdempotencyStore(nil)

	r.SetMaxToolIterations(50)
	if r.MaxToolIterations != 50 {
		t.Errorf("SetMaxToolIterations failed: got %d, want 50", r.MaxToolIterations)
	}

	r.SetMemoryStoreProvider(func(u string) *memory.MemoryStore { return nil })
}

func TestRunner_RetryChat(t *testing.T) {
	t.Parallel()
	userMsg := "ok"
	mock := &MockProvider{
		Responses: []*provider.ChatResponse{
			{Message: agentctx.StrategicMessage{Content: &agentctx.MessageContent{Str: &userMsg}}},
		},
	}
	r := &AgentRunner{
		Prov:    mock,
		Breaker: resilience.New("mock", 3, time.Minute, time.Second),
		Limiter: rate.NewLimiter(rate.Inf, 1),
	}

	resp, err := r.RetryChat(context.Background(), testSess, provider.ChatRequest{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if *resp.Message.Content.Str != "ok" {
		t.Errorf("got %q, want 'ok'", *resp.Message.Content.Str)
	}
}

func TestRunner_ExecuteTool(t *testing.T) {
	t.Parallel()
	r := &AgentRunner{
		SideEffectingTools: map[string]bool{"write": true},
	}
	r.SetTools([]Tool{&mockTool{name: "write"}})

	// Without IdempStore, it should just call inner
	got, err := r.executeTool(context.Background(), testSess, testUser, "idem-1", "write", nil, "model")
	if err != nil {
		t.Fatal(err)
	}
	if got != testResult {
		t.Errorf("got %q, want %q", got, testResult)
	}
}

func TestRunner_GenerateIdempotencyKey(t *testing.T) {
	t.Parallel()

	key1 := GenerateIdempotencyKey()
	if key1 == "" {
		t.Error("expected non-empty key")
	}
}

func TestIsCronSession(t *testing.T) {
	t.Parallel()
	if !bot.IsCronSession("cron:morning_briefing:email:user@example.com") {
		t.Fatal("expected cron session to be detected")
	}
	if bot.IsCronSession("telegram:12345") {
		t.Fatal("did not expect non-cron session to be detected")
	}
}

func TestResearcherPromptPrefersGoogleAISearch(t *testing.T) {
	t.Parallel()
	prompt := DefaultSpecialistPrompt(RoleResearcher)
	if !strings.Contains(prompt, "Google AI Search MCP tool first") {
		t.Fatalf("researcher prompt should prefer Google AI Search, got %q", prompt)
	}
	if !strings.Contains(prompt, "Do not use the regular `google_search` tool") {
		t.Fatalf("researcher prompt should discourage regular google_search for briefing, got %q", prompt)
	}
}

type stateCheckingTool struct {
	name string
	run  func(context.Context, string, string, map[string]any) (string, error)
}

func (s stateCheckingTool) Name() string { return s.name }
func (s stateCheckingTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{Name: s.name}
}
func (s stateCheckingTool) Execute(ctx context.Context, session, user string, args map[string]any) (string, error) {
	return s.run(ctx, session, user, args)
}

//nolint:cyclop,paralleltest // Checks identity, exact keys and cache behavior against one shared DB.
func TestRunner_CallStateKeys(t *testing.T) {
	root := t.TempDir()
	t.Cleanup(agentctx.ResetCheckpointManagerInstancesForTest)
	mgr, err := agentctx.GetCheckpointManager(root)
	if err != nil {
		t.Fatal(err)
	}
	store := agentctx.NewIdempotencyStore(mgr.DB(), time.Hour)
	args := map[string]any{"value": "original"}
	hash, err := agentctx.HashParams(args)
	if err != nil {
		t.Fatal(err)
	}
	calls := 0
	tool := stateCheckingTool{name: "write", run: func(_ context.Context, session, user string, got map[string]any) (string, error) {
		calls++
		if user != testUser || got["value"] != "original" || (session != testSess && session != "other") {
			t.Fatalf("identity/args lost: %s %s %v", session, user, got)
		}
		return "full stored result", nil
	}}
	other := tool
	other.name = "other_tool"
	r := &AgentRunner{IdempStore: store, SideEffectingTools: map[string]bool{"write": true, "other_tool": true}, MaxToolResultBytes: 4}
	r.ToolsByName = map[string]Tool{"write": tool, "other_tool": other}
	for _, tc := range []struct {
		label, session, name string
		iter, seq, wantCalls int
	}{
		{"first", testSess, "write", 2, 7, 1},
		{"repeat", testSess, "write", 2, 7, 1},
		{"session", "other", "write", 2, 7, 2},
		{"iteration", testSess, "write", 3, 7, 3},
		{"sequence", testSess, "write", 2, 8, 4},
		{"tool", testSess, "other_tool", 2, 7, 5},
	} {
		t.Run(tc.label, func(t *testing.T) {
			got, err := r.executeSingleToolCall(context.Background(), tc.session, testUser, tc.name, args, tc.iter, tc.seq)
			if err != nil || got != TruncateToolResult("full stored result", 4) || calls != tc.wantCalls {
				t.Fatalf("got %q, %v, calls %d", got, err, calls)
			}
			key := fmt.Sprintf("%s-%d-%d-%s-%s", tc.session, tc.iter, tc.seq, tc.name, hash)
			cached, err := store.Check(context.Background(), key, tc.name, hash)
			if err != nil || !cached.Found || cached.CachedResult != "full stored result" {
				t.Fatalf("key %q: %+v, %v", key, cached, err)
			}
		})
	}
}

//nolint:gocognit,paralleltest // Compares hash-failure behavior across side-effect/store combinations.
func TestRunner_CallStateHashFailure(t *testing.T) {
	root := t.TempDir()
	t.Cleanup(agentctx.ResetCheckpointManagerInstancesForTest)
	mgr, err := agentctx.GetCheckpointManager(root)
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name                     string
		side, store, wantFailure bool
	}{
		{"read with store", false, true, false}, {"write without store", true, false, false}, {"write with store", true, true, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tool := &countingTool{name: "write", resp: testResult}
			r := &AgentRunner{SideEffectingTools: map[string]bool{"write": tc.side}}
			if tc.store {
				r.IdempStore = agentctx.NewIdempotencyStore(mgr.DB(), time.Hour)
			}
			r.ToolsByName = map[string]Tool{"write": tool}
			got, err := r.executeSingleToolCall(context.Background(), testSess, testUser, "write", map[string]any{"bad": make(chan int)}, 1, 1)
			if err != nil {
				t.Fatal(err)
			}
			if tc.wantFailure {
				if tool.calls != 0 || !strings.Contains(got, "TOOL_ERROR [write]: executeTool: hash params:") {
					t.Fatalf("got %q, calls %d", got, tool.calls)
				}
			} else if got != testResult || tool.calls != 1 {
				t.Fatalf("got %q, calls %d", got, tool.calls)
			}
		})
	}
}

//nolint:cyclop,gocognit // Table covers hook order and the distinct error propagation branches.
func TestRunner_CallStateHookFlow(t *testing.T) {
	t.Parallel()
	const mutatedValue = "after"
	for _, tc := range []struct {
		name, override string
		toolErr        error
		cron           bool
	}{
		{name: "success"}, {name: "override", override: "override result"},
		{name: "ordinary", toolErr: errors.New("failed")}, {name: "cron", toolErr: errors.New("failed"), cron: true},
		{name: "cancel", toolErr: context.Canceled}, {name: "deadline", toolErr: context.DeadlineExceeded}, {name: "denied", toolErr: agent.ErrToolDenied},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			args := map[string]any{"value": "before"}
			events := []string{}
			hooks := &agent.Hooks{}
			hooks.RegisterPreTool(func(_ context.Context, session, name string, got map[string]any) (string, error) {
				events = append(events, "pre")
				if name != "write" || session == "" {
					t.Fatal("hook identity lost")
				}
				got["value"] = mutatedValue
				return tc.override, nil
			})
			hooks.RegisterPostTool(func(_ context.Context, _ string, result any) any {
				events = append(events, "post")
				return result.(string) + " post"
			})
			tool := stateCheckingTool{name: "write", run: func(_ context.Context, _, user string, got map[string]any) (string, error) {
				events = append(events, "execute")
				if user != testUser || got["value"] != mutatedValue {
					t.Fatal("identity or hook mutation lost")
				}
				return testResult, tc.toolErr
			}}
			r := &AgentRunner{Hooks: hooks, MaxToolResultBytes: 8}
			r.SetTools([]Tool{tool})
			session := testSess
			if tc.cron {
				session = "cron:test:user"
			}
			got, err := r.executeSingleToolCall(context.Background(), session, testUser, "write", args, 1, 1)
			wantEvents, want := "pre,execute,post", testResult+" post"
			switch {
			case tc.override != "":
				wantEvents, want = "pre", tc.override
			case tc.toolErr != nil:
				wantEvents = "pre,execute"
				if tc.cron || errors.Is(tc.toolErr, context.Canceled) || errors.Is(tc.toolErr, context.DeadlineExceeded) || errors.Is(tc.toolErr, agent.ErrToolDenied) {
					if !errors.Is(err, tc.toolErr) || got != "" {
						t.Fatalf("got %q, %v", got, err)
					}
					if tc.cron && !strings.Contains(err.Error(), "tool failure in fail-closed cron session [write]") {
						t.Fatal(err)
					}
				} else {
					want = r.handleCategoryAError(session, "write", "", testResult, fmt.Errorf("execute tool: %w", tc.toolErr))
				}
			}
			if err == nil && got != TruncateToolResult(want, 8) {
				t.Fatalf("got %q, want %q", got, TruncateToolResult(want, 8))
			}
			if tc.toolErr == nil && err != nil {
				t.Fatal(err)
			}
			if strings.Join(events, ",") != wantEvents || args["value"] != mutatedValue {
				t.Fatalf("events %v, args %v", events, args)
			}
		})
	}
}

func TestRunner_CallStatePreHookError(t *testing.T) {
	t.Parallel()
	failure := errors.New("pre failed")
	hooks := &agent.Hooks{}
	hooks.RegisterPreTool(func(context.Context, string, string, map[string]any) (string, error) { return "", failure })
	tool := &countingTool{name: "write", resp: testResult}
	r := &AgentRunner{Hooks: hooks}
	r.SetTools([]Tool{tool})
	got, err := r.executeSingleToolCall(context.Background(), testSess, testUser, "write", nil, 1, 1)
	if got != "" || !errors.Is(err, failure) || err.Error() != "pre-tool hook: pre tool hook: pre failed" || tool.calls != 0 {
		t.Fatalf("got %q, %v, calls %d", got, err, tool.calls)
	}
}
