package app_test

import (
	"context"
	"sync"
	"testing"
	"time"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/allthingscode/gobot/internal/app"
	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/agent"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/memory"
	"github.com/allthingscode/gobot/internal/memory/vector"
	"github.com/allthingscode/gobot/internal/provider"
	"github.com/allthingscode/gobot/internal/cron"
)

type mockRunner struct {
	reply string
}

func (r *mockRunner) Run(ctx context.Context, sessionKey, userID string, messages []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error) {
	return r.reply, messages, nil
}

func (r *mockRunner) RunText(ctx context.Context, sessionKey, prompt, modelOverride string) (string, error) {
	return r.reply, nil
}

type mockProvider struct {
	name string
}

func (p *mockProvider) Name() string                        { return p.name }
func (p *mockProvider) Models() []provider.ModelInfo        { return nil }
func (p *mockProvider) Chat(ctx context.Context, req provider.ChatRequest) (*provider.ChatResponse, error) {
	return &provider.ChatResponse{
		Message: agentctx.StrategicMessage{
			Role:    agentctx.RoleAssistant,
			Content: &agentctx.MessageContent{Str: appStrPtr("done")},
		},
	}, nil
}

type mockBotAPI struct {
	sent []bot.OutboundMessage
}

func (m *mockBotAPI) Updates(ctx context.Context, timeout int) (<-chan bot.InboundMessage, error) { return nil, nil }
func (m *mockBotAPI) Callbacks(ctx context.Context) (<-chan bot.InboundCallback, error) { return nil, nil }
func (m *mockBotAPI) Send(ctx context.Context, msg bot.OutboundMessage) error {
	m.sent = append(m.sent, msg)
	return nil
}
func (m *mockBotAPI) SendWithButtons(ctx context.Context, msg bot.OutboundMessage, buttons [][]bot.Button) error {
	return nil
}
func (m *mockBotAPI) Typing(ctx context.Context, chatID, threadID int64) func() { return func() {} }
func (m *mockBotAPI) Stop() {}

func appStrPtr(s string) *string { return &s }

const helloStr = "hello"

func TestDispatchHandler_Functional(t *testing.T) {
	t.Parallel()
	
	runner := &mockRunner{reply: "hello"}
	mgr := agent.NewSessionManager(runner, nil, "test-model")
	
	h := &app.DispatchHandler{
		Mgr: mgr,
	}
	
	ctx := context.Background()
	
	// Test admin command
	reply, err := h.Handle(ctx, "session1", bot.InboundMessage{Text: "/reset_circuits"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if reply != "All circuit breakers have been reset." {
		t.Errorf("expected reset reply, got %q", reply)
	}
	
	// Test normal message
	reply, err = h.Handle(ctx, "session1", bot.InboundMessage{Text: "hi", ChatID: 1, SenderID: 2})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if reply != helloStr {
		t.Errorf("expected %s, got %q", helloStr, reply)
	}
}

func TestSetupLogging_Minimal(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("skipping file logging test on Windows due to file lock")
	}
	t.Parallel()
	tempDir := t.TempDir()
	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = tempDir
	cfg.Logging.Level = "DEBUG"
	cfg.Logging.Format = "json"
	
	app.SetupLogging(cfg, nil)
}

func TestRecoverWithStack_Coverage(t *testing.T) {
	t.Parallel()
	defer func() {
		if r := recover(); r != nil {
			t.Errorf("RecoverWithStack did not prevent panic propagation: %v", r)
		}
	}()
	
	// Test recovery
	func() {
		defer app.RecoverWithStack("test-task")
		panic("test panic")
	}()
}

//nolint:paralleltest // uses global state
func TestAwareness_Functional(t *testing.T) {
	// Not parallel because it mutates global userHomeDir hook
	tempDir := t.TempDir()
	
	// Mock home dir
	oldHome := app.SetUserHomeDir(func() (string, error) {
		return tempDir, nil
	})
	defer app.SetUserHomeDir(oldHome)
	
	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = tempDir
	
	// Test EnsureAwarenessFile
	app.EnsureAwarenessFile(cfg)
	awarenessPath := filepath.Join(tempDir, "workspace", "AWARENESS.md")
	if _, err := os.Stat(awarenessPath); err != nil {
		t.Errorf("EnsureAwarenessFile did not create file: %v", err)
	}
	
	// Test LoadSystemPrompt
	_ = os.MkdirAll(filepath.Join(tempDir, ".gobot"), 0o755)
	_ = os.WriteFile(filepath.Join(tempDir, ".gobot", "SOUL.md"), []byte("Be nice"), 0o600)
	
	prompt := app.LoadSystemPrompt(cfg)
	if !strings.Contains(prompt, "Be nice") {
		t.Error("LoadSystemPrompt missing SOUL content from home dir")
	}
	if !strings.Contains(prompt, "STRATEGIC AWARENESS") {
		t.Error("LoadSystemPrompt missing awareness content")
	}
}

func TestPanic_RecoverWithStack(t *testing.T) {
	t.Parallel()
	// Just for coverage of the stack trace printing
	app.RecoverWithStack("test")
	// No panic here, just testing the deferred call
}

func TestSpawnTool_Coverage(t *testing.T) {
	t.Parallel()
	
	prov := &mockProvider{name: "mock"}
	cfg := &config.Config{}
	
	tool := app.NewSpawnTool(prov, "model", nil, nil, nil, cfg)
	
	ctx := context.Background()
	// This will still use NewAgentRunner internally which might be hard to mock completely without more work,
	// but it should hit many code paths in Execute.
	_, _ = tool.Execute(ctx, "session", "user", map[string]any{
		"agent_type": "researcher",
		"objective": "test",
	})
}

func TestCronDispatcher_Functional(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()
	
	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = tempDir
	cfg.Strategic.UserEmail = "test@example.com"
	
	stack := &app.AgentStack{
		Runner: &app.AgentRunner{}, // will be ignored by NewCronDispatcher as it uses stack.NewSessionManager
	}
	
	api := &mockBotAPI{}
	b := bot.New(api, nil)
	
	cd := app.NewCronDispatcher(cfg, nil, stack, b)
	
	ctx := context.Background()
	
	// Test Alert
	p := cron.Payload{
		Channel: "telegram",
		To:      "telegram:12345",
		Message: "alert message",
	}
	err := cd.Alert(ctx, p)
	if err != nil {
		t.Fatalf("Alert failed: %v", err)
	}
	if len(api.sent) == 0 {
		t.Error("Alert did not send message")
	}
}

func TestHeartbeatRunner_Functional(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()
	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = tempDir
	cfg.Strategic.UserChatID = 12345
	
	hb := app.NewHeartbeatRunner(cfg, "tok")
	
	ctx := context.Background()
	hb.HeartbeatCheck(ctx)
	
	// Check if LIVENESS file was written
	livenessPath := filepath.Join(tempDir, "LIVENESS")
	if _, err := os.Stat(livenessPath); err != nil {
		t.Errorf("HeartbeatCheck did not create LIVENESS file: %v", err)
	}
}

func TestInitMemory_Coverage(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()
	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = tempDir
	
	runner := &app.AgentRunner{}
	mem, cleanup := app.InitMemory(cfg, runner)
	if mem == nil {
		t.Error("expected memory store, got nil")
	}
	cleanup()
}

func TestTruncateResult_Coverage(t *testing.T) {
	t.Parallel()
	res := app.TruncateToolResult("hello world", 5)
	if !strings.Contains(res, "hello") {
		t.Errorf("unexpected truncate: %s", res)
	}
}

func TestSetupConsolidator_Coverage(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	cfg.Agents.Defaults.Compaction.Strategy = "memoryFlush"
	cfg.Agents.Defaults.Compaction.MemoryFlush.TTL = "1h"
	cfg.Agents.Defaults.Compaction.Summarization.Enabled = true
	
	stack := &app.AgentStack{
		Runner:   &app.AgentRunner{},
		MemStore: &memory.MemoryStore{},
		VecStore: &vector.Store{},
		EmbedProv: &mockEmbeddingProvider{},
	}
	mgr := agent.NewSessionManager(stack.Runner, nil, "model")
	handler := &app.DispatchHandler{}
	
	app.SetupConsolidator(cfg, stack, mgr, handler, nil, nil)
}

type mockEmbeddingProvider struct{}
func (m *mockEmbeddingProvider) EmbedStrings(ctx context.Context, texts []string) ([][]float32, error) { return nil, nil }
func (m *mockEmbeddingProvider) Embed(ctx context.Context, text string) ([]float32, error) { return nil, nil }

func TestTgAPI_IsDuplicate_Coverage(t *testing.T) {
	t.Parallel()
	api := &app.TgAPI{}
	if api.IsDuplicate("key1") {
		t.Error("first call should not be duplicate")
	}
	if !api.IsDuplicate("key1") {
		t.Error("second call should be duplicate")
	}
}

func TestRegisterTools_Coverage(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	cfg.Providers.Google.APIKey = "key"
	cfg.Providers.Google.CustomCX = "cx"
	cfg.Strategic.UserEmail = "test@example.com"
	cfg.Strategic.GmailReadonly = false
	
	reg := app.NewToolRegistry(t.TempDir())
	tools := app.RegisterTools(cfg, nil, "model", nil, nil, nil, reg, nil)
	if len(tools) == 0 {
		t.Error("RegisterTools returned no tools")
	}
}

func TestDispatchHandler_HandleCallback_Coverage(t *testing.T) {
	t.Parallel()
	h := &app.DispatchHandler{}
	err := h.HandleCallback(context.Background(), bot.InboundCallback{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestReadTextFileTool_Error(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = t.TempDir()
	tool := app.NewReadTextFileTool(cfg)
	_, err := tool.Execute(context.Background(), "s", "u", map[string]any{
		"file_path": "non-existent",
	})
	if err == nil {
		t.Error("expected error for non-existent file")
	}
}

func TestGoogleTools_Functional(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	
	tools := []app.Tool{
		app.NewListCalendarTool(dir),
		app.NewListTasksTool(dir),
		app.NewCreateTaskTool(dir),
	}
	
	ctx := context.Background()
	for _, tool := range tools {
		// Just smoke test that they fail gracefully without config/mock
		_, _ = tool.Execute(ctx, "s", "u", map[string]any{"title": "test", "summary": "test", "start_time": "2026-04-23T10:00:00Z", "end_time": "2026-04-23T11:00:00Z"})
	}
}

func TestSetupHooks_Coverage(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()
	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = tempDir
	
	// Add a policy file
	policyFile := filepath.Join(tempDir, "tool_policy.yaml")
	_ = os.WriteFile(policyFile, []byte("policies:\n  - name: test\n    tool: '*'\n    decision: allow\n"), 0o600)
	
	runner := &app.AgentRunner{}
	mgr := agent.NewSessionManager(runner, nil, "model")
	api := &mockBotAPI{}
	
	hooks, hitl := app.SetupHooks(cfg, runner, mgr, api, nil)
	if hooks == nil || hitl == nil {
		t.Error("SetupHooks returned nil")
	}
}

func TestNewTgAPI_Error_Coverage(t *testing.T) {
	t.Parallel()
	_, err := app.NewTgAPI("invalid-token", nil, &config.Config{})
	if err == nil {
		t.Error("expected error for invalid token")
	}
}

func TestIndexMemory_Coverage(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	store, err := memory.NewMemoryStore(dir)
	if err != nil {
		t.Fatalf("NewMemoryStore failed: %v", err)
	}
	defer func() { _ = store.Close() }()
	
	h := &app.DispatchHandler{
		Memory: store,
	}
	h.IndexMemory("sess", "long user message to avoid skip", "reply")
	
	// Case 2: skip
	h.IndexMemory("sess", "ok", "reply")
}

func TestMaybeHandleAdminCommand_Coverage(t *testing.T) {
	t.Parallel()
	h := &app.DispatchHandler{}
	reply, ok := h.MaybeHandleAdminCommand("sess", "/reset_circuits")
	if !ok || reply == "" {
		t.Error("admin command not handled")
	}
	
	_, ok = h.MaybeHandleAdminCommand("sess", "not a command")
	if ok {
		t.Error("non-command handled as admin command")
	}
}

func TestRunnerUtils_Coverage(t *testing.T) {
	t.Parallel()
	
	// ExtractText
	msg := agentctx.StrategicMessage{
		Content: &agentctx.MessageContent{Str: appStrPtr("hello")},
	}
	if app.ExtractText(msg) != "hello" {
		t.Error("ExtractText failed")
	}
	
	// LastUserText
	history := []agentctx.StrategicMessage{
		{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: appStrPtr("hi")}},
		{Role: agentctx.RoleAssistant, Content: &agentctx.MessageContent{Str: appStrPtr("ho")}},
	}
	if app.LastUserText(history) != "hi" {
		t.Error("LastUserText failed")
	}
	
	// BuildCorrectionMessage
	report := map[string]any{
		"feedback": "fix this",
		"required_corrections": []any{"one", "two"},
	}
	corr := app.BuildCorrectionMessage(report)
	if !strings.Contains(corr, "fix this") || !strings.Contains(corr, "one") {
		t.Error("BuildCorrectionMessage failed")
	}
	
	// GenerateIdempotencyKey
	k1 := app.GenerateIdempotencyKey()
	k2 := app.GenerateIdempotencyKey()
	if k1 == "" || k1 == k2 {
		t.Error("GenerateIdempotencyKey failed")
	}
}

func TestResolveEmailSubject_Coverage(t *testing.T) {
	t.Parallel()
	p := cron.Payload{
		Subject: "Briefing for {{DATE}}",
	}
	got := app.ResolveEmailSubject(p)
	if !strings.Contains(got, "Briefing") {
		t.Errorf("ResolveEmailSubject failed: %s", got)
	}
}

func TestHandleSystemJob_Coverage(t *testing.T) {
	t.Parallel()
	cd := &app.CronDispatcher{}
	if !cd.HandleSystemJob(context.Background(), cron.Payload{Message: "[SYSTEM] INDEX_WORKSPACE"}) {
		t.Error("INDEX_WORKSPACE not handled as system job")
	}
}

func TestSetupGateHandler_Coverage(t *testing.T) {
	t.Parallel()
	h := app.SetupGateHandler(nil, &app.DispatchHandler{})
	if h == nil {
		t.Error("SetupGateHandler returned nil")
	}
}

func TestAgentRunner_CallTool_Coverage(t *testing.T) {
	t.Parallel()
	r := &app.AgentRunner{}
	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = t.TempDir()
	r.SetTools([]app.Tool{app.NewReadTextFileTool(cfg)})
	
	// Tool exists but will fail due to missing file
	res, err := r.ExecuteSingleToolCall(context.Background(), "sess", "user", "read_text_file", map[string]any{"file_path": "test"}, 0, 1)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(res, "Error") {
		t.Errorf("expected error message in result, got %q", res)
	}
	
	// Unknown tool
	res, err = r.ExecuteSingleToolCall(context.Background(), "sess", "user", "unknown", nil, 0, 1)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(res, "unknown tool") {
		t.Errorf("expected unknown tool message in result, got %q", res)
	}
}

func TestShellExecTool_Coverage(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()
	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = tempDir
	tool := app.NewShellExecTool(cfg, 1*time.Second, nil)
	
	ctx := context.Background()
	
	// Case 1: missing command
	_, err := tool.Execute(ctx, "sess", "user", map[string]any{})
	if err == nil {
		t.Error("expected error for missing command")
	}
	
	// Case 2: simple command (echo) — cross-platform
	var cmd string
	var args []any
	if runtime.GOOS == "windows" {
		cmd = "cmd"
		args = []any{"/c", "echo", "hello"}
	} else {
		cmd = "sh"
		args = []any{"-c", "echo hello"}
	}
	res, err := tool.Execute(ctx, "sess", "user", map[string]any{
		"command": cmd,
		"args":    args,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(res, "hello") {
		t.Errorf("expected hello in output, got %q", res)
	}
}

//nolint:paralleltest // uses global state
func TestLoadPrivateFile_Coverage(t *testing.T) {
	tempDir := t.TempDir()
	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = tempDir
	
	_ = os.MkdirAll(filepath.Join(tempDir, ".gobot"), 0o755)
	_ = os.WriteFile(filepath.Join(tempDir, ".gobot", "TEST.md"), []byte("data"), 0o600)
	
	// Mock home dir
	oldHome := app.SetUserHomeDir(func() (string, error) {
		return tempDir, nil
	})
	defer app.SetUserHomeDir(oldHome)
	
	got := app.LoadPrivateFile(cfg, "TEST.md")
	if got != "data" {
		t.Errorf("expected data, got %q", got)
	}
	
	// Case 2: missing
	got2 := app.LoadPrivateFile(cfg, "MISSING.md")
	if got2 != "" {
		t.Errorf("expected empty for missing, got %q", got2)
	}
}

func TestNewAgentRunner_Coverage(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	cfg.Agents.Defaults.MemoryWindow = 10
	r := app.NewAgentRunner(&mockProvider{}, "model", "prompt", cfg)
	if r == nil {
		t.Error("NewAgentRunner returned nil")
	}
}

func TestCronDispatcher_Dispatch_Coverage(t *testing.T) {
	t.Parallel()
	// Just coverage of initialization for now
	stack := &app.AgentStack{
		Runner: &app.AgentRunner{},
	}
	_ = app.NewCronDispatcher(&config.Config{}, nil, stack, nil)
}

func TestLiveProbes_Coverage(t *testing.T) {
	t.Parallel()
	p := app.LiveProbes()
	if p == nil {
		t.Error("LiveProbes returned nil")
	}
}

func TestMemoryStore_Rebuild_Coverage(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	sessionsDir := filepath.Join(dir, "sessions")
	_ = os.MkdirAll(sessionsDir, 0o755)
	_ = os.WriteFile(filepath.Join(sessionsDir, "sess1.md"), []byte("data"), 0o600)
	
	// NewMemoryStore expects a dir where it will create workspace/memory.db
	store, err := memory.NewMemoryStore(dir)
	if err != nil {
		t.Fatalf("NewMemoryStore failed: %v", err)
	}
	defer func() { _ = store.Close() }()
	
	count, err := store.Rebuild(sessionsDir)
	if err != nil || count != 1 {
		t.Errorf("Rebuild failed: %v, count=%d", err, count)
	}
}

func TestStartGateway_NilListener_Coverage(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	cfg.Gateway.Host = "127.0.0.1"
	cfg.Gateway.Port = 0
	var wg sync.WaitGroup
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // stop immediately
	
	app.StartGateway(ctx, cfg, nil, nil, nil, &wg)
	wg.Wait()
}

func TestInitProviders_Coverage(t *testing.T) {
	t.Parallel()
	provider.ResetForTest()
	cfg := &config.Config{}
	cfg.Providers.Gemini.APIKey = "AIzaSyTest"
	
	_, _, _ = app.InitProviders(context.Background(), cfg) //nolint:errcheck // smoke test
}

func TestBuildAgentStack_Routing_Coverage(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	cfg.Strategic.Routing.Enabled = true
	
	_, _, _ = app.BuildAgentStack(context.Background(), cfg, nil)
}

func TestBuildAgentStack_Errors(t *testing.T) { //nolint:paralleltest // uses global state // resets global provider registry
	provider.ResetForTest()
	cfg := &config.Config{}
	_, _, err := app.BuildAgentStack(context.Background(), cfg, nil)
	if err == nil {
		t.Error("expected error for empty config")
	}
}
