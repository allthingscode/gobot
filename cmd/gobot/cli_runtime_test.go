//nolint:testpackage // tests unexported runtime helpers
package main

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/app"
	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/doctor"
	"github.com/allthingscode/gobot/internal/observability"
	"github.com/allthingscode/gobot/internal/reporter"
)

func TestNewCLISessionManagerWithDepsSimulateMode(t *testing.T) {
	t.Parallel()

	runner := &app.AgentRunner{}
	cleanupCalled := false
	hooksCalled := false

	deps := cliRuntimeDeps{
		runDoctorDiagnostics: func(_ *config.Config, _ *doctor.Probes) error { return nil },
		buildCLIStack: func(_ context.Context, _ *config.Config, _ *reporter.TemplateManager, _ *observability.DispatchTracer) (*app.AgentStack, func(), error) {
			return &app.AgentStack{Runner: runner, Model: "test-model"}, func() { cleanupCalled = true }, nil
		},
		getCheckpointManager: func(string) (*agentctx.CheckpointManager, error) { return nil, nil },
		setupRuntimeHooks: func(_ *config.Config, _ *app.AgentRunner, _ *agent.SessionManager, _ bot.API, _ agent.CheckpointStore) (*agent.Hooks, *agent.HITLManager) {
			hooksCalled = true
			return &agent.Hooks{}, nil
		},
	}

	mgr, cleanup, err := newCLISessionManagerWithDeps(context.Background(), &config.Config{}, cliHooksModeSimulate, deps)
	if err != nil {
		t.Fatalf("newCLISessionManagerWithDeps returned error: %v", err)
	}
	if mgr == nil {
		t.Fatal("expected non-nil session manager")
	}
	if hooksCalled {
		t.Fatal("simulate mode should not call setupRuntimeHooks")
	}
	if runner.Hooks == nil {
		t.Fatal("simulate mode should install post-dispatch hooks")
	}

	cleanup()
	if !cleanupCalled {
		t.Fatal("cleanup function was not called")
	}
}

func TestNewCLISessionManagerWithDepsInteractiveMode(t *testing.T) {
	t.Parallel()

	runner := &app.AgentRunner{}
	hooksCalled := false

	deps := cliRuntimeDeps{
		runDoctorDiagnostics: func(_ *config.Config, _ *doctor.Probes) error { return nil },
		buildCLIStack: func(_ context.Context, _ *config.Config, _ *reporter.TemplateManager, _ *observability.DispatchTracer) (*app.AgentStack, func(), error) {
			return &app.AgentStack{Runner: runner, Model: "test-model"}, func() {}, nil
		},
		getCheckpointManager: func(string) (*agentctx.CheckpointManager, error) { return nil, nil },
		setupRuntimeHooks: func(_ *config.Config, _ *app.AgentRunner, mgr *agent.SessionManager, _ bot.API, _ agent.CheckpointStore) (*agent.Hooks, *agent.HITLManager) {
			hooksCalled = true
			hooks := &agent.Hooks{}
			mgr.SetHooks(hooks)
			runner.SetHooks(hooks)
			return hooks, nil
		},
	}

	mgr, cleanup, err := newCLISessionManagerWithDeps(context.Background(), &config.Config{}, cliHooksModeInteractive, deps)
	if err != nil {
		t.Fatalf("newCLISessionManagerWithDeps returned error: %v", err)
	}
	if mgr == nil {
		t.Fatal("expected non-nil session manager")
	}
	if !hooksCalled {
		t.Fatal("interactive mode should call setupRuntimeHooks")
	}

	cleanup()
}

func TestNewCLISessionManagerWithDepsBuildError(t *testing.T) {
	t.Parallel()

	deps := cliRuntimeDeps{
		runDoctorDiagnostics: func(_ *config.Config, _ *doctor.Probes) error { return nil },
		buildCLIStack: func(_ context.Context, _ *config.Config, _ *reporter.TemplateManager, _ *observability.DispatchTracer) (*app.AgentStack, func(), error) {
			return nil, nil, fmt.Errorf("boom")
		},
		getCheckpointManager: func(string) (*agentctx.CheckpointManager, error) { return nil, nil },
		setupRuntimeHooks: func(_ *config.Config, _ *app.AgentRunner, _ *agent.SessionManager, _ bot.API, _ agent.CheckpointStore) (*agent.Hooks, *agent.HITLManager) {
			return &agent.Hooks{}, nil
		},
	}

	_, _, err := newCLISessionManagerWithDeps(context.Background(), &config.Config{}, cliHooksModeInteractive, deps)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if got := err.Error(); got == "" || !containsAll(got, "build agent stack", "boom") {
		t.Fatalf("unexpected error message: %q", got)
	}
}

func containsAll(s string, parts ...string) bool {
	for _, p := range parts {
		if !strings.Contains(s, p) {
			return false
		}
	}
	return true
}
