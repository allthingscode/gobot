package main

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/app"
	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/doctor"
	"github.com/allthingscode/gobot/internal/observability"
	"github.com/allthingscode/gobot/internal/reporter"
)

type cliHooksMode int

const (
	cliHooksModeSimulate cliHooksMode = iota
	cliHooksModeInteractive
)

func newCLISessionManager(ctx context.Context, cfg *config.Config, mode cliHooksMode) (*agent.SessionManager, func(), error) {
	return newCLISessionManagerWithDeps(ctx, cfg, mode, cliRuntimeDeps{
		runDoctorDiagnostics: doctor.Run,
		buildCLIStack:        app.BuildAgentStack,
		getCheckpointManager: agentctx.GetCheckpointManager,
		setupRuntimeHooks:    app.SetupHooks,
	})
}

type cliRuntimeDeps struct {
	runDoctorDiagnostics func(cfg *config.Config, probes *doctor.Probes) error
	buildCLIStack        func(ctx context.Context, cfg *config.Config, tmgr *reporter.TemplateManager, tracer *observability.DispatchTracer) (*app.AgentStack, func(), error)
	getCheckpointManager func(dbDir string) (*agentctx.CheckpointManager, error)
	setupRuntimeHooks    func(cfg *config.Config, runner *app.AgentRunner, mgr *agent.SessionManager, api bot.API, store agent.CheckpointStore) (*agent.Hooks, *agent.HITLManager)
}

func newCLISessionManagerWithDeps(ctx context.Context, cfg *config.Config, mode cliHooksMode, deps cliRuntimeDeps) (*agent.SessionManager, func(), error) {
	// Pre-flight diagnostics mirror run/simulate behavior; warnings are non-fatal.
	if err := deps.runDoctorDiagnostics(cfg, nil); err != nil {
		slog.Warn("pre-flight diagnostics found issues", "err", err)
	}

	tmgr := reporter.NewTemplateManagerWithCSS(cfg.TemplatesPath(), cfg.Strategic.CustomCSSPath)
	stack, cleanup, err := deps.buildCLIStack(ctx, cfg, tmgr, nil)
	if err != nil {
		return nil, nil, fmt.Errorf("build agent stack: %w", err)
	}

	store, _ := deps.getCheckpointManager(cfg.StorageRoot())
	mgr := stack.NewSessionManager(cfg, store, nil)

	switch mode {
	case cliHooksModeInteractive:
		_, _ = deps.setupRuntimeHooks(cfg, stack.Runner, mgr, nil, store)
	default:
		// Keep simulate behavior stable: post-dispatch hooks only.
		hooks := &agent.Hooks{}
		hooks.RegisterPostDispatch(agent.NewHandoffHook(cfg.StorageRoot()))
		mgr.SetHooks(hooks)
		stack.Runner.SetHooks(hooks)
	}

	return mgr, cleanup, nil
}
