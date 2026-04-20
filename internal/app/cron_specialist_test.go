//nolint:testpackage // testing unexported CronDispatcher fields
package app

import (
	"context"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/cron"
	"github.com/allthingscode/gobot/internal/provider"
)

const (
	mockName      = "mock"
	telegramConst = "telegram"
)

type mockAPI struct {
	bot.API
	sent []bot.OutboundMessage
}

func (m *mockAPI) Send(_ context.Context, msg bot.OutboundMessage) error {
	m.sent = append(m.sent, msg)
	return nil
}

func (m *mockAPI) Typing(_ context.Context, _, _ int64) func() {
	return func() {}
}

type mockChatProvider struct {
	provider.Provider
	resp string
}

func (m *mockChatProvider) Name() string { return mockName }
func (m *mockChatProvider) Chat(_ context.Context, _ provider.ChatRequest) (*provider.ChatResponse, error) {
	return &provider.ChatResponse{
		Message: agentctx.StrategicMessage{
			Role:    agentctx.RoleAssistant,
			Content: &agentctx.MessageContent{Str: &m.resp},
		},
	}, nil
}

func TestCronDispatcher_DispatchSpecialist_Telegram(t *testing.T) { //nolint:paralleltest // modifies global provider registry
	mockProv := &mockChatProvider{resp: "Mock Specialist Result"}
	provider.ResetForTest()
	t.Cleanup(provider.ResetForTest)
	if err := provider.Register(mockProv); err != nil {
		t.Fatalf("failed to register mock provider: %v", err)
	}

	cfg := &config.Config{
		Agents: config.AgentsConfig{
			Specialists: map[string]config.SpecialistConfig{
				"researcher": {Model: "gpt-researcher", Provider: mockName},
			},
		},
	}

	api := &mockAPI{}
	b := bot.New(api, nil)

	p := cron.Payload{
		ID:      "job123",
		Message: "Research AI",
		Agent:   "researcher",
		Channel: telegramConst,
		To:      "telegram:12345",
	}

	var capturedModel string
	cd := &CronDispatcher{
		cfg: cfg,
		b:   b,
		runnerFactory: func(prov provider.Provider, model, systemPrompt string) *AgentRunner {
			capturedModel = model
			return NewAgentRunner(prov, model, systemPrompt, cfg)
		},
	}

	err := cd.Dispatch(context.Background(), p)
	if err != nil {
		t.Fatalf("Dispatch failed: %v", err)
	}

	if capturedModel != "gpt-researcher" {
		t.Errorf("expected model gpt-researcher, got %q", capturedModel)
	}

	if len(api.sent) != 1 {
		t.Fatalf("expected 1 message sent, got %d", len(api.sent))
	}

	msg := api.sent[0]
	if msg.ChatID != 12345 {
		t.Errorf("expected ChatID 12345, got %d", msg.ChatID)
	}
	if msg.Text != "Mock Specialist Result" {
		t.Errorf("expected text 'Mock Specialist Result', got %q", msg.Text)
	}
}

func TestCronDispatcher_DispatchSpecialist_Unknown(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{
		Agents: config.AgentsConfig{
			Specialists: map[string]config.SpecialistConfig{},
		},
	}

	cd := &CronDispatcher{
		cfg: cfg,
	}

	p := cron.Payload{
		Agent: "unknown-spec",
	}

	err := cd.Dispatch(context.Background(), p)
	if err == nil {
		t.Error("expected error for unknown specialist, got nil")
	}
	if !strings.Contains(err.Error(), "unknown specialist: unknown-spec") {
		t.Errorf("unexpected error message: %v", err)
	}
}
