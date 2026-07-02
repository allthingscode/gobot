//nolint:testpackage // covers package-private helpers
package app

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/browser"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/cron"
	"github.com/allthingscode/gobot/internal/integrations/google"
	"github.com/allthingscode/gobot/internal/provider"
	"github.com/allthingscode/gobot/internal/reporter"
)

type nopWriteCloser struct {
	bytes.Buffer
}

const (
	coverageEmailBody    = "body"
	coverageRecipient    = "user@example.com"
	coverageFakeProvider = "fake-build"
	coverageStoredResult = "stored-result"
)

func (n *nopWriteCloser) Close() error { return nil }

func TestBuildEmailContentPlainAndHTML(t *testing.T) {
	t.Parallel()

	plain := buildEmailContent(nil, "Subject", "Body")
	if plain.Subject != "Subject" || plain.Plain != "Body" || plain.HTML != "" {
		t.Fatalf("plain email content = %#v", plain)
	}

	html := buildEmailContent(reporter.NewTemplateManager(""), "Subject", "<h1>Title</h1><p>Body</p>")
	if html.HTML == "" || !strings.Contains(html.Plain, "Title") {
		t.Fatalf("expected wrapped HTML plus stripped plain text, got %#v", html)
	}
}

func TestSearchGmailToolHelpers(t *testing.T) {
	t.Parallel()

	tool := newSearchGmailTool("secrets", nil)
	if tool.Name() != searchGmailToolName {
		t.Fatalf("Name = %q", tool.Name())
	}
	if got := tool.parseMaxResults(map[string]any{}); got != 5 {
		t.Fatalf("default max results = %d", got)
	}
	if got := tool.parseMaxResults(map[string]any{"max_results": float64(12)}); got != 12 {
		t.Fatalf("float max results = %d", got)
	}

	summaries := []google.MessageSummary{{ID: "m1"}, {ID: "m2"}}
	messages := []*google.Message{
		{
			ID:      "m1",
			Snippet: "hello",
			Payload: &google.Payload{Headers: []google.Header{
				{Name: "From", Value: "a@example.com"},
				{Name: "Subject", Value: "Greetings"},
			}},
		},
		nil,
	}
	got := tool.formatResults(summaries, messages)
	for _, want := range []string{"Found 2 messages", "**ID**: m1", "a@example.com", "Greetings", "Error loading details"} {
		if !strings.Contains(got, want) {
			t.Fatalf("formatResults missing %q in %q", want, got)
		}
	}
}

func TestSendEmailToolAuthErrorBranch(t *testing.T) {
	t.Parallel()

	tool := newSendEmailTool(t.TempDir(), t.TempDir(), coverageRecipient, NewToolRegistry(t.TempDir()), nil, nil)
	_, err := tool.Execute(context.Background(), "cron:job:email:user@example.com", "", map[string]any{
		"subject": "Subject",
		"body":    "Body",
	})
	if err == nil || !strings.Contains(err.Error(), "send_email: auth") {
		t.Fatalf("expected send_email auth error, got %v", err)
	}
}

func TestReadGmailToolNameAndValidation(t *testing.T) {
	t.Parallel()

	tool := newReadGmailTool("secrets", nil)
	if tool.Name() != readGmailToolName {
		t.Fatalf("Name = %q", tool.Name())
	}
	if _, err := tool.Execute(context.Background(), "", "", map[string]any{}); err == nil || !strings.Contains(err.Error(), "message_id is required") {
		t.Fatalf("expected message_id validation error, got %v", err)
	}
}

func TestGoogleToolParsingAndValidationBranches(t *testing.T) {
	t.Parallel()

	cal := newListCalendarTool("secrets", nil)
	for _, tc := range []struct {
		args map[string]any
		want int
	}{
		{map[string]any{}, 10},
		{map[string]any{"max_results": float64(3)}, 3},
		{map[string]any{"max_results": int(4)}, 4},
		{map[string]any{"max_results": int64(5)}, 5},
		{map[string]any{"max_results": 0}, 10},
	} {
		if got := cal.parseMaxResults(tc.args); got != tc.want {
			t.Fatalf("parseMaxResults(%v)=%d want=%d", tc.args, got, tc.want)
		}
	}

	ctx := context.Background()
	if _, err := newCompleteTaskTool("secrets", nil).Execute(ctx, "", "", map[string]any{}); err == nil {
		t.Fatal("expected complete task id validation error")
	}
	if _, err := newUpdateTaskTool("secrets", nil).Execute(ctx, "", "", map[string]any{}); err == nil {
		t.Fatal("expected update task id validation error")
	}
	if _, err := newCreateCalendarEventTool("secrets", nil).Execute(ctx, "", "", map[string]any{"summary": "Meet"}); err == nil {
		t.Fatal("expected calendar start_time validation error")
	}
	if _, err := newCreateCalendarEventTool("secrets", nil).Execute(ctx, "", "", map[string]any{"summary": "Meet", "start_time": "2026-07-02T10:00:00Z"}); err == nil {
		t.Fatal("expected calendar end_time validation error")
	}
	if _, err := newWebSearchTool("key", "cx", nil).Execute(ctx, "", "", map[string]any{}); err == nil {
		t.Fatal("expected web search query validation error")
	}
}

func TestGoogleToolsAuthErrorBranches(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	secretsRoot := t.TempDir()
	cases := []struct {
		name string
		run  func() (string, error)
		want string
	}{
		{
			name: "list calendar",
			run: func() (string, error) {
				return newListCalendarTool(secretsRoot, nil).Execute(ctx, "", "", map[string]any{"max_results": float64(1)})
			},
			want: "list_calendar_events:",
		},
		{
			name: "list tasks",
			run: func() (string, error) {
				return newListTasksTool(secretsRoot, nil).Execute(ctx, "", "", map[string]any{"tasklist_id": "mine"})
			},
			want: "list_tasks:",
		},
		{
			name: "create task",
			run: func() (string, error) {
				return newCreateTaskTool(secretsRoot, nil).Execute(ctx, "", "", map[string]any{"title": "Task", "notes": "Notes", "tasklist_id": "mine"})
			},
			want: "create_task:",
		},
		{
			name: "complete task",
			run: func() (string, error) {
				return newCompleteTaskTool(secretsRoot, nil).Execute(ctx, "", "", map[string]any{"task_id": "task-1", "tasklist_id": "mine"})
			},
			want: "complete_task:",
		},
		{
			name: "update task",
			run: func() (string, error) {
				return newUpdateTaskTool(secretsRoot, nil).Execute(ctx, "", "", map[string]any{"task_id": "task-1", "title": "New", "notes": "N", "due": "2026-07-02T10:00:00Z"})
			},
			want: "update_task:",
		},
		{
			name: "create calendar event",
			run: func() (string, error) {
				return newCreateCalendarEventTool(secretsRoot, nil).Execute(ctx, "", "", map[string]any{
					"calendar_id": "primary",
					"summary":     "Meet",
					"description": "Discuss",
					"start_time":  "2026-07-02T10:00:00Z",
					"end_time":    "2026-07-02T11:00:00Z",
					"location":    "Office",
				})
			},
			want: "create_calendar_event:",
		},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			_, err := tc.run()
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("expected %q error, got %v", tc.want, err)
			}
		})
	}
}

func TestCronEmailFailureHelpers(t *testing.T) {
	t.Parallel()

	p := cron.Payload{ID: morningBriefingJobID, Subject: "Daily {{DATE}}"}
	subject := resolveFailureEmailSubject(p)
	if !strings.Contains(subject, "Failed: Daily") {
		t.Fatalf("failure subject = %q", subject)
	}

	called := false
	cd := &CronDispatcher{failureEmailHook: func(_ context.Context, got cron.Payload, recipient, body string) {
		called = true
		if got.ID != morningBriefingJobID || recipient != coverageRecipient || body != coverageEmailBody {
			t.Fatalf("unexpected hook args: %#v %q %q", got, recipient, body)
		}
	}}
	cd.sendFailureEmail(context.Background(), cron.Payload{ID: morningBriefingJobID}, coverageRecipient, coverageEmailBody)
	if !called {
		t.Fatal("failure email hook was not called")
	}
}

func TestWebExtractPayloadAndGuidanceHelpers(t *testing.T) {
	t.Parallel()

	for _, tc := range []struct {
		classification string
		want           string
	}{
		{constraintAuthRequired, "authentication"},
		{constraintAntiBotBlocked, "anti-bot"},
		{constraintDynamicPending, "dynamic content"},
		{constraintUnsupported, "not supported"},
		{constraintNone, "No page constraints"},
	} {
		if got := guidanceForClassification(tc.classification); !strings.Contains(got, tc.want) {
			t.Fatalf("guidanceForClassification(%q)=%q want substring %q", tc.classification, got, tc.want)
		}
	}

	payload := marshalConstraintPayload(constraintDynamicPending, "dynamic_wait_error")
	for _, want := range []string{`"status":"constraint_blocked"`, `"classification":"dynamic_pending"`, `"retryable":true`} {
		if !strings.Contains(payload, want) {
			t.Fatalf("payload missing %q in %q", want, payload)
		}
	}

	if class, signal := classifyPageConstraint("Unsupported Browser", `{"snippet":"Enable JavaScript"}`, browser.DynamicWaitResult{Completed: true}); class != constraintUnsupported || signal != "unsupported_runtime" {
		t.Fatalf("unsupported classification = %q/%q", class, signal)
	}
	if class, signal := classifyPageConstraint("Normal", `{"snippet":"Loaded"}`, browser.DynamicWaitResult{Completed: true}); class != constraintNone || signal != constraintNone {
		t.Fatalf("none classification = %q/%q", class, signal)
	}
	if pageSnippet(`not-json`) != "" {
		t.Fatal("invalid page map should return empty snippet")
	}
}

func TestWebExtractToolMetadata(t *testing.T) {
	t.Parallel()

	tool := newWebExtractTool(&config.Config{}, nil, "model")
	if tool.Name() != webExtractToolName {
		t.Fatalf("Name = %q", tool.Name())
	}
	decl := tool.Declaration()
	if decl.Name != webExtractToolName || decl.Description == "" || decl.Parameters["type"] != "object" {
		t.Fatalf("unexpected declaration: %#v", decl)
	}
}

func TestTgAPITrivialMethods(t *testing.T) {
	t.Parallel()

	api := &TgAPI{username: "botname"}
	if api.Username() != "botname" {
		t.Fatalf("Username = %q", api.Username())
	}
	callbacks, err := api.Callbacks(context.Background())
	if err != nil {
		t.Fatalf("Callbacks: %v", err)
	}
	if callbacks == nil {
		t.Fatal("Callbacks returned nil channel")
	}
	api.Stop()
}

func TestMCPServerErrorBranches(t *testing.T) {
	t.Parallel()

	srv := &MCPServer{name: "test"}
	if err := srv.stop(); err != nil {
		t.Fatalf("stop without process: %v", err)
	}

	srv.stdin = &nopWriteCloser{}
	srv.stdout = io.NopCloser(strings.NewReader(`{"id":2}` + "\n"))
	if _, err := srv.callLocked(context.Background(), 1, map[string]any{"id": 1}); err == nil || !strings.Contains(err.Error(), "EOF before response id 1") {
		t.Fatalf("expected EOF before matching response, got %v", err)
	}
}

//nolint:cyclop,paralleltest // Single test owns the fake MCP process lifecycle.
func TestMCPServerStartCallAndStop(t *testing.T) {
	//nolint:paralleltest // spawns this test binary as a subprocess
	ctx := context.Background()
	srv := &MCPServer{
		name: "helper",
		cfg: config.MCPServerConfig{
			Command: os.Args[0],
			Args:    []string{"-test.run=TestMCPServerHelperProcess", "--"},
		},
		env: map[string]string{"GO_WANT_MCP_HELPER": "1"},
	}

	resp, err := srv.Call(ctx, "tools/list", map[string]any{"limit": 1})
	if err != nil {
		t.Fatalf("Call: %v; stderr=%s", err, srv.stderr.String())
	}
	if !strings.Contains(resp, `"tools"`) {
		t.Fatalf("unexpected response: %q", resp)
	}
	if !srv.initialized || srv.lastID != 2 {
		t.Fatalf("server state not initialized: initialized=%v lastID=%d", srv.initialized, srv.lastID)
	}
	if err := srv.start(ctx); err != nil {
		t.Fatalf("second start should be no-op: %v", err)
	}
	if err := srv.stop(); err != nil {
		t.Fatalf("stop: %v", err)
	}
	if srv.cmd != nil || srv.stdin != nil || srv.stdout != nil || srv.initialized {
		t.Fatalf("stop did not clear state: %#v", srv)
	}
}

//nolint:paralleltest // Helper process test is gated by GO_WANT_HELPER_PROCESS.
func TestMCPServerHelperProcess(t *testing.T) {
	if os.Getenv("GO_WANT_MCP_HELPER") != "1" {
		return
	}
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		line := scanner.Text()
		var req struct {
			ID     int    `json:"id"`
			Method string `json:"method"`
		}
		if err := json.Unmarshal([]byte(line), &req); err != nil || req.ID == 0 {
			continue
		}
		resp := map[string]any{"jsonrpc": "2.0", "id": req.ID}
		if req.Method == "tools/list" {
			resp["result"] = map[string]any{
				"tools": []map[string]any{{
					"name":        "helper_tool",
					"description": "helper",
					"inputSchema": map[string]any{"type": "object"},
				}},
			}
		} else {
			resp["result"] = map[string]any{"ok": true}
		}
		_ = json.NewEncoder(os.Stdout).Encode(resp)
	}
	os.Exit(0)
}

func TestMCPProxyToolErrorWrap(t *testing.T) {
	t.Parallel()

	caller := &mockMCPCaller{name: "srv", err: errors.New("down")}
	tool := &mcpProxyTool{server: caller, toolName: "do", decl: providerToolDecl("do")}
	if _, err := tool.Execute(context.Background(), "", "", map[string]any{"x": 1}); err == nil || !strings.Contains(err.Error(), "tools/call: down") {
		t.Fatalf("expected wrapped tools/call error, got %v", err)
	}
}

func providerToolDecl(name string) provider.ToolDeclaration {
	return provider.ToolDeclaration{Name: name}
}

type fakeSpawnRunner struct {
	textResp string
	textErr  error
	runResp  string
	runErr   error
	limit    int
}

type fakeBuildProvider struct{}

func (fakeBuildProvider) Name() string { return coverageFakeProvider }

func (fakeBuildProvider) Chat(context.Context, provider.ChatRequest) (*provider.ChatResponse, error) {
	text := "ok"
	return &provider.ChatResponse{
		Message: agentctx.StrategicMessage{Content: &agentctx.MessageContent{Str: &text}},
	}, nil
}

func (fakeBuildProvider) Models() []provider.ModelInfo {
	return []provider.ModelInfo{{ID: "fake-model"}}
}

type fakeTool struct {
	name  string
	resp  string
	err   error
	panic bool
}

func (f fakeTool) Name() string { return f.name }

func (f fakeTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{Name: f.name}
}

func (f fakeTool) Execute(context.Context, string, string, map[string]any) (string, error) {
	if f.panic {
		panic("boom")
	}
	return f.resp, f.err
}

type countingTool struct {
	name  string
	resp  string
	calls int
}

func (c *countingTool) Name() string { return c.name }

func (c *countingTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{Name: c.name}
}

func (c *countingTool) Execute(context.Context, string, string, map[string]any) (string, error) {
	c.calls++
	return c.resp, nil
}

func (f *fakeSpawnRunner) RunText(context.Context, string, string, string) (string, error) {
	return f.textResp, f.textErr
}

func (f *fakeSpawnRunner) Run(context.Context, string, string, []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error) {
	return f.runResp, nil, f.runErr
}

func (f *fakeSpawnRunner) SetMaxToolIterations(n int) {
	f.limit = n
}

//nolint:cyclop // Covers wrapper forwarding and error branches together.
func TestIterLimitRunnerBranches(t *testing.T) {
	t.Parallel()

	inner := &fakeSpawnRunner{textResp: "text", runResp: "run"}
	runner := &iterLimitRunner{Inner: inner, Max: 1}
	runner.SetMaxToolIterations(3)
	if inner.limit != 3 {
		t.Fatalf("inner limit = %d", inner.limit)
	}
	text, err := runner.RunText(context.Background(), "s", "prompt", "")
	if err != nil || text != "text" {
		t.Fatalf("RunText = %q, %v", text, err)
	}
	resp, _, err := runner.Run(context.Background(), "s", "u", nil)
	if err != nil || resp != "run" {
		t.Fatalf("Run = %q, %v", resp, err)
	}
	if _, _, err := runner.Run(context.Background(), "s", "u", nil); err == nil || !strings.Contains(err.Error(), "exceeded maximum iterations") {
		t.Fatalf("expected iteration limit error, got %v", err)
	}

	textErrRunner := &iterLimitRunner{Inner: &fakeSpawnRunner{textErr: errors.New("text failed")}, Max: 1}
	if _, err := textErrRunner.RunText(context.Background(), "s", "prompt", ""); err == nil || !strings.Contains(err.Error(), "run text") {
		t.Fatalf("expected RunText wrapper error, got %v", err)
	}
	runErrRunner := &iterLimitRunner{Inner: &fakeSpawnRunner{runErr: errors.New("run failed")}, Max: 1}
	if _, _, err := runErrRunner.Run(context.Background(), "s", "u", nil); err == nil || !strings.Contains(err.Error(), "run: run failed") {
		t.Fatalf("expected Run wrapper error, got %v", err)
	}
}

//nolint:paralleltest // Registers a package-global fake provider.
func TestBuildAgentStackWithRegisteredFakeProvider(t *testing.T) {
	//nolint:paralleltest // mutates global provider registry
	provider.ResetForTest()
	t.Cleanup(provider.ResetForTest)
	if err := provider.Register(fakeBuildProvider{}); err != nil {
		t.Fatalf("Register: %v", err)
	}

	cfg := &config.Config{}
	cfg.Runtime.StorageRoot = t.TempDir()
	cfg.Agents.Defaults.Provider = coverageFakeProvider
	cfg.Agents.Defaults.Model = "fake-model"

	stack, cleanup, err := BuildAgentStack(context.Background(), cfg, nil, nil)
	if err != nil {
		t.Fatalf("BuildAgentStack: %v", err)
	}
	defer cleanup()
	if stack == nil || stack.Runner == nil || stack.Prov.Name() != coverageFakeProvider || stack.Model != "fake-model" {
		t.Fatalf("unexpected stack: %#v", stack)
	}
}

func TestExecuteToolInnerBranches(t *testing.T) {
	t.Parallel()

	runner := &AgentRunner{ToolsByName: map[string]Tool{
		"ok":    fakeTool{name: "ok", resp: "done"},
		"panic": fakeTool{name: "panic", panic: true},
	}}
	got, err := runner.executeTool(context.Background(), "session", "user", "", "ok", map[string]any{"x": 1}, "")
	if err != nil || got != "done" {
		t.Fatalf("executeTool success = %q, %v", got, err)
	}
	if _, err := runner.executeToolInner(context.Background(), "session", "user", "missing", nil); err == nil || !strings.Contains(err.Error(), "unknown tool") {
		t.Fatalf("expected unknown tool error, got %v", err)
	}
	if _, err := runner.executeToolInner(context.Background(), "session", "user", "panic", nil); err == nil || !strings.Contains(err.Error(), "panicked") {
		t.Fatalf("expected panic recovery error, got %v", err)
	}
}

//nolint:cyclop,paralleltest // Exercises miss, hit, mismatch, and empty-hash idempotency branches against one DB.
func TestExecuteToolIdempotencyBranches(t *testing.T) {
	root := t.TempDir()
	t.Cleanup(agentctx.ResetCheckpointManagerInstancesForTest)

	mgr, err := agentctx.GetCheckpointManager(root)
	if err != nil {
		t.Fatalf("GetCheckpointManager: %v", err)
	}
	store := agentctx.NewIdempotencyStore(mgr.DB(), time.Hour)
	tool := &countingTool{name: "side_effect", resp: coverageStoredResult}
	runner := &AgentRunner{
		ToolsByName:        map[string]Tool{"side_effect": tool},
		SideEffectingTools: map[string]bool{"side_effect": true},
		IdempStore:         store,
	}
	args := map[string]any{"value": "one"}
	hash, err := agentctx.HashParams(args)
	if err != nil {
		t.Fatalf("HashParams: %v", err)
	}

	got, err := runner.executeTool(context.Background(), "session", "user", "idem-key", "side_effect", args, hash)
	if err != nil || got != coverageStoredResult {
		t.Fatalf("first executeTool = %q, %v", got, err)
	}
	got, err = runner.executeTool(context.Background(), "session", "user", "idem-key", "side_effect", args, hash)
	if err != nil || got != coverageStoredResult {
		t.Fatalf("cached executeTool = %q, %v", got, err)
	}
	if tool.calls != 1 {
		t.Fatalf("tool executed %d times, want cache hit after first call", tool.calls)
	}

	otherHash, err := agentctx.HashParams(map[string]any{"value": "two"})
	if err != nil {
		t.Fatalf("HashParams other: %v", err)
	}
	if _, err := runner.executeTool(context.Background(), "session", "user", "idem-key", "side_effect", args, otherHash); !agentctx.IsIdempotencyHashMismatch(err) {
		t.Fatalf("expected idempotency hash mismatch, got %v", err)
	}

	tool.calls = 0
	got, err = runner.executeTool(context.Background(), "session", "user", "empty-hash-key", "side_effect", args, "")
	if err != nil || got != coverageStoredResult || tool.calls != 1 {
		t.Fatalf("empty hash executeTool = %q, calls=%d, err=%v", got, tool.calls, err)
	}
}

func TestCronMorningBriefingFailureAndGuardBranches(t *testing.T) {
	t.Parallel()

	called := false
	cd := &CronDispatcher{
		shutdownCh: make(chan struct{}),
		failureEmailHook: func(_ context.Context, p cron.Payload, recipient, body string) {
			called = true
			if p.ID != morningBriefingJobID || recipient != coverageRecipient || !strings.Contains(body, "AUTH_EXPIRED") {
				t.Fatalf("unexpected failure email args: %#v %q %q", p, recipient, body)
			}
		},
	}
	cd.handleMorningBriefingDispatchFailure(
		context.Background(),
		cron.Payload{ID: morningBriefingJobID, Message: "brief me"},
		coverageRecipient,
		"cron:morning_briefing:email:user@example.com",
		errors.New("AUTH_EXPIRED: run gobot reauth"),
	)
	if !called {
		t.Fatal("failure email hook was not called")
	}

	if err := cd.enforceMorningBriefingGuards("session", ""); err == nil || !strings.Contains(err.Error(), "empty response") {
		t.Fatalf("expected empty response guard error, got %v", err)
	}
}

func TestCronResponseBranchesWithoutRecipients(t *testing.T) {
	t.Parallel()

	cd := &CronDispatcher{}
	cd.sendSpecialistResponse(context.Background(), cron.Payload{}, chanEmail, "", "response")
	cd.sendSpecialistResponse(context.Background(), cron.Payload{}, "unknown", "", "response")
	cd.sendTelegramResponse(context.Background(), "not-a-session-key", "response")
}

func TestDispatchSilentBranches(t *testing.T) {
	t.Parallel()

	cd := &CronDispatcher{}
	if err := cd.dispatchSilent(context.Background(), cron.Payload{Message: "skip"}, ""); err != nil {
		t.Fatalf("empty recipient should be ignored: %v", err)
	}

	runner := &fakeSpawnRunner{runResp: "ignored"}
	cd.mgr = agent.NewSessionManager(runner, nil, "fake-model")
	if err := cd.dispatchSilent(context.Background(), cron.Payload{Message: "work"}, "telegram:123"); err != nil {
		t.Fatalf("dispatchSilent: %v", err)
	}
}

func TestDispatchTelegramSendsResponse(t *testing.T) {
	t.Parallel()

	api := &appMockAPI{msgChan: make(chan bot.InboundMessage)}
	cd := &CronDispatcher{
		mgr: agent.NewSessionManager(&fakeSpawnRunner{runResp: "telegram response"}, nil, "fake-model"),
		b:   bot.New(api, &appMockHandler{}),
	}
	if err := cd.dispatchTelegram(context.Background(), cron.Payload{Message: "hello"}, "telegram:123"); err != nil {
		t.Fatalf("dispatchTelegram: %v", err)
	}
	if !api.sendCalled {
		t.Fatal("expected cron response to be sent")
	}
}

func TestDispatchHandlerCallbackNoHITL(t *testing.T) {
	t.Parallel()

	h := &DispatchHandler{}
	if err := h.HandleCallback(context.Background(), bot.InboundCallback{ChatID: 1}); err != nil {
		t.Fatalf("HandleCallback without HITL: %v", err)
	}
}

func TestLiveProbesListErrorBranches(t *testing.T) {
	t.Parallel()

	probes := LiveProbesList()
	if probes == nil {
		t.Fatal("LiveProbesList returned nil")
	}
	if _, err := probes.ProbeTelegram("bad token with spaces"); err == nil {
		t.Fatal("expected invalid telegram token error")
	}
	if err := probes.ProbeGmail(t.TempDir()); err == nil || !strings.Contains(err.Error(), "new google service") {
		t.Fatalf("expected gmail service error, got %v", err)
	}
	if !shouldRetryGeminiProbe(errors.New("429 resource_exhausted")) {
		t.Fatal("429/resource_exhausted should retry")
	}
}

func TestAwaitReadyForBannerReadyAndContextBranches(t *testing.T) {
	t.Parallel()

	cfg := &config.Config{}
	cfg.Gateway.Enabled = true
	ready := NewReadiness()
	ready.SetReady()
	awaitReadyForBanner(context.Background(), cfg, ready)

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	awaitReadyForBanner(ctx, cfg, NewReadiness())
}
