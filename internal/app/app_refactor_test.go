//nolint:testpackage // needs unexported identifiers: TgAPI, isDuplicate, dedupTTL, seenMsgs
package app

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/time/rate"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/cron"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/observability"
	"github.com/allthingscode/gobot/internal/provider"
	"github.com/allthingscode/gobot/internal/resilience"
	telego "github.com/mymmrac/telego"
)

const replyText = "reply"

type appMockAPI struct {
	bot.API
	sendCalled bool
	msgChan    chan bot.InboundMessage
}

func (m *appMockAPI) Updates(ctx context.Context, timeout int) (<-chan bot.InboundMessage, error) {
	return m.msgChan, nil
}
func (m *appMockAPI) Callbacks(ctx context.Context) (<-chan bot.InboundCallback, error) {
	return make(chan bot.InboundCallback), nil
}
func (m *appMockAPI) Send(ctx context.Context, msg bot.OutboundMessage) error {
	m.sendCalled = true
	return nil
}
func (m *appMockAPI) SendWithButtons(ctx context.Context, msg bot.OutboundMessage, buttons [][]bot.Button) error {
	m.sendCalled = true
	return nil
}
func (m *appMockAPI) Typing(ctx context.Context, chatID, threadID int64) func() {
	return func() {}
}

type appMockHandler struct {
	handleCalled bool
}

func (m *appMockHandler) Handle(ctx context.Context, sessionKey string, msg bot.InboundMessage) (string, error) {
	m.handleCalled = true
	return replyText, nil
}
func (m *appMockHandler) HandleCallback(ctx context.Context, cb bot.InboundCallback) error {
	return nil
}

func TestStartTelegramBot_Injected(t *testing.T) {
	t.Parallel()
	api := &appMockAPI{msgChan: make(chan bot.InboundMessage)}
	handler := &appMockHandler{}
	var wg sync.WaitGroup
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	b := StartTelegramBot(ctx, api, handler, nil, &wg)
	if b == nil {
		t.Fatal("expected non-nil bot")
	}

	cancel()
	wg.Wait()
}

func TestStartCron_Injected(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	cfg.Cron.Enabled = true
	stack := &AgentStack{Runner: &AgentRunner{}}
	var wg sync.WaitGroup
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	StartCron(ctx, cfg, stack, nil, nil, &wg)
	cancel()
	wg.Wait()
}

func TestCronDispatcher_Dispatch_App(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	api := &appMockAPI{}
	b := bot.New(api, nil)
	stack := &AgentStack{Runner: &AgentRunner{}}
	mgr := agent.NewSessionManager(stack.Runner, nil, "test")

	cd := NewCronDispatcher(cfg, mgr, stack, b)

	ctx := context.Background()

	sysPayload := cron.Payload{
		Message: "[SYSTEM] INDEX_WORKSPACE",
	}
	err := cd.Dispatch(ctx, sysPayload)
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}

	cfg.Strategic.StorageRoot = t.TempDir()
	if err := os.MkdirAll(filepath.Join(cfg.Strategic.StorageRoot, "workspace"), 0o755); err != nil {
		t.Fatalf("setup: %v", err)
	}
	silentPayload := cron.Payload{
		ID:      "job-silent",
		Message: "silent message",
		To:      "telegram:12345",
	}
	_ = cd.Dispatch(ctx, silentPayload)
}

func TestCronDispatcher_Alert_App(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	api := &appMockAPI{}
	b := bot.New(api, nil)
	cd := NewCronDispatcher(cfg, nil, &AgentStack{}, b)

	p := cron.Payload{
		Message: "alert message",
		Channel: "telegram",
		To:      "telegram:12345",
	}

	err := cd.Alert(context.Background(), p)
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	if !api.sendCalled {
		t.Error("expected API.Send to be called")
	}
}

func TestRecoverWithStack_App(t *testing.T) {
	t.Parallel()
	defer func() {
		if r := recover(); r != nil {
			t.Errorf("RecoverWithStack panicked: %v", r)
		}
	}()
	RecoverWithStack("test")
}

func TestRunAgent_BuildStackFail_App(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	cfg.Agents.Defaults.Provider = "invalid-provider"
	err := RunAgent(context.Background(), cfg)
	if err == nil {
		t.Error("expected error from RunAgent with invalid provider")
	}
}

func TestTgAPI_IsDuplicate_App(t *testing.T) {
	t.Parallel()
	api := &TgAPI{}
	if api.isDuplicate("chat1:msg1") {
		t.Error("first call should not be duplicate")
	}
	if !api.isDuplicate("chat1:msg1") {
		t.Error("second call should be duplicate")
	}

	api.seenMsgs.Store("chat2:msg2", time.Now().Add(-dedupTTL-time.Second))
	if api.isDuplicate("chat2:msg2") {
		t.Error("expired entry should have been evicted and not reported as duplicate")
	}
}

func TestTgAPI_HandleUpdate_Callback_App(t *testing.T) {
	t.Parallel()
	api := &TgAPI{
		msgChan: make(chan bot.InboundMessage, 1),
		cbChan:  make(chan bot.InboundCallback, 1),
	}

	cbUpdate := telego.Update{
		CallbackQuery: &telego.CallbackQuery{
			ID:   "cb1",
			Data: "data1",
			From: telego.User{ID: 456},
		},
	}
	defer func() {
		_ = recover()
	}()
	api.handleUpdate(context.Background(), cbUpdate)
}

func TestBuildAgentStack_Basic_App(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = t.TempDir()

	stack, cleanup, err := BuildAgentStack(context.Background(), cfg, nil)
	if err != nil {
		t.Logf("BuildAgentStack failed as expected (likely no keys): %v", err)
	}
	if stack != nil {
		cleanup()
	}
}

func TestInitProviders_Routing_App(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	cfg.Strategic.Routing.Enabled = true
	_, _, err := InitProviders(context.Background(), cfg)
	if err != nil {
		t.Logf("InitProviders failed: %v", err)
	}
}

func TestAgentRunner_Setters_App(t *testing.T) {
	t.Parallel()
	r := &AgentRunner{}
	r.SetHooks(&agent.Hooks{})
	r.SetTracer(&observability.DispatchTracer{})
}

func TestReadTextFileTool_App(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	workspaceDir := filepath.Join(tmpDir, "workspace")
	if err := os.MkdirAll(workspaceDir, 0o755); err != nil {
		t.Fatal(err)
	}
	filePath := filepath.Join(workspaceDir, "test.txt")
	if err := os.WriteFile(filePath, []byte("hello world"), 0o600); err != nil {
		t.Fatalf("setup: %v", err)
	}

	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = tmpDir

	tool := NewReadTextFileTool(cfg)

	res, err := tool.Execute(context.Background(), "", "", map[string]any{"file_path": "test.txt"})
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	if res != "hello world" {
		t.Errorf("expected 'hello world', got %q", res)
	}

	_, err = tool.Execute(context.Background(), "", "", map[string]any{"file_path": "../outside.txt"})
	if err == nil {
		t.Error("expected error for path outside workspace")
	}
}

func TestExtractText_App(t *testing.T) {
	t.Parallel()
	s := "test" //nolint:goconst // recurring test string in isolated test logic
	msg1 := agentctx.StrategicMessage{Content: &agentctx.MessageContent{Str: &s}}
	if ExtractText(msg1) != "test" {
		t.Errorf("expected 'test', got %q", ExtractText(msg1))
	}

	msg2 := agentctx.StrategicMessage{Content: &agentctx.MessageContent{
		Items: []agentctx.ContentItem{
			{Text: &agentctx.TextContent{Text: "hello "}},
			{Text: &agentctx.TextContent{Text: "world"}},
		},
	}}
	if ExtractText(msg2) != "hello world" {
		t.Errorf("expected 'hello world', got %q", ExtractText(msg2))
	}

	msg3 := agentctx.StrategicMessage{}
	if ExtractText(msg3) != "" {
		t.Errorf("expected empty string, got %q", ExtractText(msg3))
	}
}

func TestDispatchHandler_App(t *testing.T) {
	t.Parallel()
	h := &DispatchHandler{}

	reply, ok := h.maybeHandleAdminCommand("sess", "/reset_circuits")
	if !ok || !strings.Contains(reply, "reset") {
		t.Errorf("expected /reset_circuits to be handled, got %q, %v", reply, ok)
	}
}

func TestAgentRunner_RunText_App(t *testing.T) {
	t.Parallel()
	userMsg := replyText
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

	res, err := r.RunText(context.Background(), "sess", "prompt", "")
	if err != nil {
		t.Fatal(err)
	}
	if res != replyText {
		t.Errorf("got %q, want %q", res, replyText)
	}
}

func TestTgAPI_SendMethods_App(t *testing.T) {
	t.Parallel()
	api := &TgAPI{
		breaker: resilience.New("telegram", 3, time.Minute, time.Second),
	}

	defer func() {
		_ = recover()
	}()
	_ = api.Send(context.Background(), bot.OutboundMessage{})
	_ = api.SendWithButtons(context.Background(), bot.OutboundMessage{}, nil)
}

func TestCronDispatcher_DispatchSpecialist_App(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	cfg.Agents.Specialists = map[string]config.SpecialistConfig{
		"test": {Model: "model", Provider: "mock"},
	}
	cd := &CronDispatcher{cfg: cfg}

	p := cron.Payload{Agent: "unknown"}
	err := cd.Dispatch(context.Background(), p)
	if err == nil || !strings.Contains(err.Error(), "unknown specialist") {
		t.Errorf("expected unknown specialist error, got %v", err)
	}
}

func TestHeartbeatRunner_App(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = tmpDir

	hb := NewHeartbeatRunner(cfg, "token")
	if hb == nil {
		t.Fatal("NewHeartbeatRunner returned nil")
	}

	hb.writeLivenessFile(0)
	if _, err := os.Stat(filepath.Join(tmpDir, "LIVENESS")); err != nil {
		t.Errorf("LIVENESS file not written: %v", err)
	}
}

func TestAwareness_App(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = tmpDir

	content := buildAwarenessContent(cfg)
	if !strings.Contains(content, "STRATEGIC AWARENESS") {
		t.Error("awareness content missing header")
	}

	EnsureAwarenessFile(cfg)
	awarenessPath := filepath.Join(tmpDir, "workspace", "AWARENESS.md")
	if _, err := os.Stat(awarenessPath); err != nil {
		t.Errorf("AWARENESS.md not written: %v", err)
	}

	prompt := LoadSystemPrompt(cfg)
	if prompt == "" {
		t.Log("LoadSystemPrompt returned empty, which is possible if no files exist")
	}
}
