//nolint:testpackage // intentionally uses unexported helpers from main package
package app

import (
	"context"
	"log/slog"
	"testing"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/memory"
)

//nolint:paralleltest // sets global logger
func TestSetupLogging(t *testing.T) {
	oldLogger := slog.Default()
	defer slog.SetDefault(oldLogger)

	cfg := &config.Config{}
	
	// Case 1: Text format
	cfg.Agents.Defaults.MaxTokens = 1 // dummy to avoid empty struct
	SetupLogging(cfg)
	slog.Info("test message")

	// Case 2: JSON format
	cfg.Gateway.DashboardEnabled = true // dummy
	
	defer func() {
		if r := recover(); r != nil {
			t.Errorf("SetupLogging panicked: %v", r)
		}
	}()
	SetupLogging(cfg)
}

func TestValidateRunPrerequisites(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	
	// Case 1: Telegram disabled, no token needed
	cfg.Channels.Telegram.Enabled = false
	if err := validateRunPrerequisites(cfg); err != nil {
		t.Errorf("unexpected error: %v", err)
	}

	// Case 2: Telegram enabled, no token -> error
	cfg.Channels.Telegram.Enabled = true
	if err := validateRunPrerequisites(cfg); err == nil {
		t.Error("expected error for missing token")
	}

	// Case 3: Telegram enabled, token set -> ok
	cfg.Channels.Telegram.Token = "test-token"
	if err := validateRunPrerequisites(cfg); err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestSetupConsolidator(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	stack := &AgentStack{
		MemStore: &memory.MemoryStore{},
	}
	mgr := &agent.SessionManager{}
	handler := &DispatchHandler{}
	
	SetupConsolidator(cfg, stack, mgr, handler, nil)
	if handler.Consolidator == nil {
		t.Error("SetupConsolidator failed to set handler.Consolidator")
	}
}

func TestSetupGateHandler(t *testing.T) {
	t.Parallel()
	handler := &DispatchHandler{}
	
	// Case 1: nil store
	got := SetupGateHandler(nil, handler)
	if got != handler {
		t.Error("expected original handler for nil store")
	}
}

func TestInitIdempotency(t *testing.T) {
	t.Parallel()
	// Just ensure it doesn't panic with nil store
	InitIdempotency(context.Background(), &config.Config{}, &AgentRunner{}, nil, nil)
}

func TestLiveProbes(t *testing.T) {
	t.Parallel()
	p := LiveProbes()
	if p == nil {
		t.Error("LiveProbes returned nil")
	}
}

func TestSetupHooks(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	runner := &AgentRunner{}
	mgr := &agent.SessionManager{}
	
	h, hitl := SetupHooks(cfg, runner, mgr, nil)
	if h == nil || hitl == nil {
		t.Error("SetupHooks returned nil")
	}
}

func TestRunAgentLoop(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithCancel(context.Background())
	// Cancel immediately to test the loop exit
	cancel()
	
	cfg := &config.Config{}
	stack := &AgentStack{Runner: &AgentRunner{}}
	
	_ = runAgentLoop(ctx, cfg, stack, nil)
}

func TestRunPreFlightDiagnostics(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	runPreFlightDiagnostics(cfg)
}
