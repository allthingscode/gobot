package main

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/memory"
	"github.com/allthingscode/gobot/internal/observability"
	"github.com/allthingscode/gobot/internal/provider"
)

// agentStack holds the core components required to run the strategic agent.
type agentStack struct {
	prov     provider.Provider
	model    string
	runner   *geminiRunner
	memStore *memory.MemoryStore // may be nil; caller must defer cleanup() if non-nil
}

// buildAgentStack extracts the shared provider, system prompt, runner, and tool
// initialization sequence used by both 'run' and 'simulate' commands.
// Returns a stack of components and a cleanup function (to close memory store).
func buildAgentStack(ctx context.Context, cfg *config.Config) (*agentStack, func(), error) {
	factory := &provider.Factory{
		GeminiAPIKey:    cfg.GeminiAPIKey(),
		AnthropicAPIKey: cfg.AnthropicAPIKey(),
		OpenAIAPIKey:    cfg.OpenAIAPIKey(),
		OpenAIBaseURL:   cfg.OpenAIBaseURL(),
	}
	if err := factory.InitAll(ctx); err != nil {
		return nil, nil, err
	}

	provName := cfg.DefaultProvider()
	prov, err := provider.Get(provName)
	if err != nil {
		return nil, nil, fmt.Errorf("provider: %w", err)
	}
	model := cfg.DefaultModel()

	// Ensure AWARENESS.md exists (mirrors launcher.py)
	ensureAwarenessFile(cfg)

	systemPrompt := loadSystemPrompt(cfg)
	if systemPrompt != "" {
		slog.Info("gobot: system prompt loaded", "bytes", len(systemPrompt))
	}

	runner := newGeminiRunner(prov, model, systemPrompt, cfg)

	// Init long-term memory store (non-fatal if it fails).
	cleanup := func() {}
	memStore, memErr := memory.NewMemoryStore(cfg.StorageRoot())
	if memErr != nil {
		slog.Warn("bootstrap: memory store unavailable, running without long-term memory", "err", memErr)
	} else if memStore != nil {
		runner.memStore = memStore
		cleanup = func() { memStore.Close() }
	}

	runner.tools = registerTools(cfg, prov, model, memStore)

	return &agentStack{
		prov:     prov,
		model:    model,
		runner:   runner,
		memStore: memStore,
	}, cleanup, nil
}

// NewSessionManager initializes a new agent.SessionManager with standard gobot defaults.
// It ensures that all commands (run, simulate, cron) use consistent settings for
// timeouts, memory window, pruning, and compaction.
func (s *agentStack) NewSessionManager(cfg *config.Config, store *agentctx.CheckpointManager, tracer *observability.DispatchTracer) *agent.SessionManager {
	mgr := agent.NewSessionManager(s.runner, store, s.model)
	if tracer != nil {
		mgr.SetTracer(tracer)
	}
	mgr.SetLockTimeout(cfg.LockTimeoutDuration())
	mgr.SetMemoryWindow(cfg.MemoryWindow())
	mgr.SetPruningPolicy(cfg.ContextPruning())
	mgr.SetCompactionPolicy(cfg.Compaction())
	mgr.SetStorageRoot(cfg.StorageRoot())
	mgr.SetLogger(agent.NewMarkdownLogger(cfg.StorageRoot())) // F-037

	return mgr
}
