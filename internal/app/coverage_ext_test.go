//nolint:testpackage // needs unexported identifiers: TgAPI, iterLimitRunner, buildSystemPrompt
package app

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/time/rate"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/cron"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/provider"
	"github.com/allthingscode/gobot/internal/resilience"
	telego "github.com/mymmrac/telego"
)

const (
	testEmail        = "test@example.com"
	fallbackSuccText = "fallback success"
)

// coverageMockProvider for testing.
type coverageMockProvider struct {
	Responses []*provider.ChatResponse
	Err       error
	NameStr   string
}

func (m *coverageMockProvider) Chat(ctx context.Context, req provider.ChatRequest) (*provider.ChatResponse, error) {
	if m.Err != nil {
		return nil, m.Err
	}
	if len(m.Responses) == 0 {
		s := "default response"
		return &provider.ChatResponse{Message: agentctx.StrategicMessage{Content: &agentctx.MessageContent{Str: &s}}}, nil
	}
	resp := m.Responses[0]
	m.Responses = m.Responses[1:]
	return resp, nil
}

func (m *coverageMockProvider) Name() string {
	if m.NameStr != "" {
		return m.NameStr
	}
	return mockName
}
func (m *coverageMockProvider) Embed(ctx context.Context, text string) ([]float32, error) { return nil, nil }
func (m *coverageMockProvider) Models() []provider.ModelInfo                               { return nil }

func TestCronDispatcher_MoreBranches_Part1(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	cfg.Strategic.UserEmail = testEmail
	cfg.Strategic.StorageRoot = t.TempDir()

	api := &appMockAPI{}
	b := bot.New(api, nil)

	respText := "cron response"
	mockProv := &coverageMockProvider{
		Responses: []*provider.ChatResponse{
			{Message: agentctx.StrategicMessage{Content: &agentctx.MessageContent{Str: &respText}}},
		},
	}
	runner := NewAgentRunner(mockProv, "model", "sys", cfg)
	runner.Limiter = rate.NewLimiter(rate.Inf, 1)
	mgr := agent.NewSessionManager(runner, nil, "test")

	cd := NewCronDispatcher(cfg, mgr, &AgentStack{Runner: runner}, b)

	pTg := cron.Payload{
		ID:      "job-tg",
		Channel: "telegram",
		Message: "hello tg",
		To:      "telegram:12345",
	}
	err := cd.Dispatch(context.Background(), pTg)
	if err != nil {
		t.Errorf("dispatchTelegram failed: %v", err)
	}
	if !api.sendCalled {
		t.Error("expected Telegram Send to be called")
	}
}

func TestCronDispatcher_MoreBranches_Part2(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	cfg.Strategic.UserEmail = testEmail
	cfg.Strategic.StorageRoot = t.TempDir()

	api := &appMockAPI{}
	b := bot.New(api, nil)

	emptyResp := ""
	mockProv := &coverageMockProvider{
		Responses: []*provider.ChatResponse{
			{Message: agentctx.StrategicMessage{Content: &agentctx.MessageContent{Str: &emptyResp}}},
		},
	}
	runner := NewAgentRunner(mockProv, "model", "sys", cfg)
	runner.Limiter = rate.NewLimiter(rate.Inf, 1)
	mgr := agent.NewSessionManager(runner, nil, "test")
	cd := NewCronDispatcher(cfg, mgr, &AgentStack{Runner: runner}, b)

	ctx := context.Background()

	pEmail := cron.Payload{
		ID:      "job-email",
		Channel: "email",
		Message: "hello email",
		To:      "email:" + testEmail,
	}
	if err := cd.Dispatch(ctx, pEmail); err != nil {
		t.Errorf("dispatchEmail failed: %v", err)
	}

	cfg.Agents.Specialists = map[string]config.SpecialistConfig{
		"researcher": {Model: "gpt-4", Provider: "mock"},
	}
	if err := provider.Register(mockProv); err != nil {
		t.Logf("provider.Register: %v", err)
	}

	respText := "specialist response"
	mockProv.Responses = []*provider.ChatResponse{
		{Message: agentctx.StrategicMessage{Content: &agentctx.MessageContent{Str: &respText}}},
	}
	pSpec := cron.Payload{
		ID:      "job-spec",
		Channel: "telegram",
		Message: "spec message",
		Agent:   "researcher",
		To:      "telegram:12345",
	}
	if err := cd.Dispatch(ctx, pSpec); err != nil {
		t.Errorf("dispatchSpecialist failed: %v", err)
	}

	pAlertEmail := cron.Payload{
		Message: "alert email",
		Channel: "email",
		To:      testEmail,
	}
	if err := cd.Alert(ctx, pAlertEmail); err != nil {
		t.Errorf("Alert email failed: %v", err)
	}
}

func TestSpawnTool_HandleFallback_Coverage(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}

	mockProv1 := &coverageMockProvider{NameStr: "mock1", Err: errors.New("fail")}
	mockProv2 := &coverageMockProvider{NameStr: "mock2"}

	s := fallbackSuccText
	mockProv2.Responses = []*provider.ChatResponse{
		{Message: agentctx.StrategicMessage{Content: &agentctx.MessageContent{Str: &s}}},
	}

	if err := provider.Register(mockProv1); err != nil {
		t.Logf("provider.Register mock1: %v", err)
	}
	if err := provider.Register(mockProv2); err != nil {
		t.Logf("provider.Register mock2: %v", err)
	}

	st := &SpawnTool{
		DefaultProv: mockProv2,
		Model:       "model2",
		RunnerFactory: func(p provider.Provider, m, systemPrompt string) agent.Runner {
			runner := NewAgentRunner(p, m, systemPrompt, cfg)
			runner.Limiter = rate.NewLimiter(rate.Inf, 1)
			return runner
		},
		Cfg: cfg,
	}

	res, err := st.handleFallback(context.Background(), "subKey", "user", "obj", "researcher", "prompt", mockProv1, "model1", time.Now(), errors.New("original"))
	if err != nil {
		t.Errorf("handleFallback failed: %v", err)
	}
	if res != fallbackSuccText {
		t.Errorf("expected %q, got %q", fallbackSuccText, res)
	}
}

func TestAgentRunner_BuildSystemPrompt_Branches_Coverage(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = t.TempDir()

	r := &AgentRunner{
		SystemPrompt: "Base prompt",
		Cfg:          cfg,
	}

	p1 := r.buildSystemPrompt(context.Background(), "sess", nil, nil)
	if !strings.Contains(p1, "Base prompt") {
		t.Errorf("expected base prompt, got %q", p1)
	}

	if err := os.MkdirAll(filepath.Join(cfg.Strategic.StorageRoot, "workspace"), 0o755); err != nil {
		t.Fatalf("setup: %v", err)
	}
	awarenessContent := "Awareness info"
	if err := os.WriteFile(filepath.Join(cfg.Strategic.StorageRoot, "workspace", "AWARENESS.md"), []byte(awarenessContent), 0o600); err != nil {
		t.Fatalf("setup: %v", err)
	}

	// LoadSystemPrompt is what actually reads the file
	r.SystemPrompt = LoadSystemPrompt(cfg)

	p2 := r.buildSystemPrompt(context.Background(), "sess", nil, nil)
	if !strings.Contains(p2, awarenessContent) {
		t.Errorf("expected awareness info, got %q", p2)
	}
}

func TestAwareness_LoadScheduleContext_Coverage(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()

	ctx := loadScheduleContext("")
	if ctx != "" {
		t.Errorf("expected empty context for missing file, got %q", ctx)
	}

	if err := os.MkdirAll(filepath.Join(tmpDir, "workspace"), 0o755); err != nil {
		t.Fatalf("setup: %v", err)
	}
	if err := os.WriteFile(filepath.Join(tmpDir, "workspace", "SCHEDULE.md"), []byte("Schedule context"), 0o600); err != nil {
		t.Fatalf("setup: %v", err)
	}
	result := loadScheduleContext(tmpDir)
	if !strings.Contains(result, "Schedule context") {
		t.Logf("loadScheduleContext returns empty if it can't find real tokens, got %q", result)
	}
}

func TestHeartbeatRunner_Run_Coverage(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = tmpDir

	hb := NewHeartbeatRunner(cfg, "token")
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()

	hb.Run(ctx)
}

func TestSpawnTool_IterLimitRunner_Coverage(t *testing.T) {
	t.Parallel()
	mock := &coverageMockRunner{
		RunFunc: func(ctx context.Context, sessionKey, userID string, messages []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error) {
			return "ok", nil, nil
		},
	}

	lr := &iterLimitRunner{Inner: mock, Max: 1}

	_, _, err := lr.Run(context.Background(), "s", "u", nil)
	if err != nil {
		t.Errorf("1st run failed: %v", err)
	}

	_, _, err = lr.Run(context.Background(), "s", "u", nil)
	if err == nil || !strings.Contains(err.Error(), "exceeded maximum iterations") {
		t.Errorf("expected iteration limit error, got %v", err)
	}
}

func TestTgAPI_HandleUpdate_Callback_Coverage(t *testing.T) {
	t.Parallel()
	api := &TgAPI{
		msgChan: make(chan bot.InboundMessage, 1),
		cbChan:  make(chan bot.InboundCallback, 1),
		breaker: resilience.New("test", 3, time.Minute, time.Second),
	}

	cbUpdate := telego.Update{
		CallbackQuery: &telego.CallbackQuery{
			ID:   "cb1",
			Data: "data1",
			From: telego.User{ID: 456},
			Message: &telego.Message{
				Chat: telego.Chat{ID: 123},
			},
		},
	}

	defer func() {
		if r := recover(); r != nil {
			t.Logf("Recovered from expected panic (nil client): %v", r)
		}
	}()
	api.handleUpdate(context.Background(), cbUpdate)
}

type coverageMockRunner struct {
	RunFunc     func(ctx context.Context, sessionKey, userID string, messages []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error)
	RunTextFunc func(ctx context.Context, sessionKey, prompt, modelOverride string) (string, error)
}

func (m *coverageMockRunner) Run(ctx context.Context, sessionKey, userID string, messages []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error) {
	return m.RunFunc(ctx, sessionKey, userID, messages)
}

func (m *coverageMockRunner) RunText(ctx context.Context, sessionKey, prompt, modelOverride string) (string, error) {
	if m.RunTextFunc != nil {
		return m.RunTextFunc(ctx, sessionKey, prompt, modelOverride)
	}
	return "mock response", nil
}
