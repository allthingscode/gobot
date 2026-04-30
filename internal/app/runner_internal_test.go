//nolint:testpackage // intentionally uses unexported helpers from main package
package app

import (
	"context"
	"strings"
	"testing"
	"time"

	"golang.org/x/time/rate"

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

func TestIsFailClosedCronSession(t *testing.T) {
	t.Parallel()
	if !isFailClosedCronSession("cron:morning_briefing:email:user@example.com") {
		t.Fatal("expected cron session to be fail-closed")
	}
	if isFailClosedCronSession("telegram:12345") {
		t.Fatal("did not expect non-cron session to be fail-closed")
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
