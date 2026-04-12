package main

import (
	"context"
	"fmt"
	"log/slog"
	"path/filepath"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/memory"
	"github.com/allthingscode/gobot/internal/memory/vector"
	"github.com/allthingscode/gobot/internal/observability"
	"github.com/allthingscode/gobot/internal/provider"
)

// agentStack holds the core components required to run the strategic agent.
type agentStack struct {
	prov      provider.Provider
	model     string
	runner    *geminiRunner
	memStore  *memory.MemoryStore // may be nil; caller must defer cleanup() if non-nil
	vecStore  *vector.Store
	embedProv vector.EmbeddingProvider
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

	// F-102: Manager-Executor Cost Routing
	if cfg.Strategic.Routing.Enabled {
		mgrProvName := cfg.Strategic.Routing.ManagerProvider
		if mgrProvName == "" {
			mgrProvName = provName
		}
		mgrProv, err := provider.Get(mgrProvName)
		if err != nil {
			slog.Warn("bootstrap: manager provider not found, disabling cost routing", "provider", mgrProvName)
		} else {
			slog.Info("bootstrap: cost routing enabled", "manager_model", cfg.Strategic.Routing.ManagerModel, "manager_provider", mgrProvName)
			prov = provider.NewRoutingProvider(prov, mgrProv, cfg.Strategic.Routing)
		}
	}

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
		cleanup = func() { _ = memStore.Close() }
	}

	// F-105: Wire per-user memory store provider when multi-user isolation is enabled.
	if cfg.MultiUserEnabled() {
		runner.SetMemoryStoreProvider(func(userID string) *memory.MemoryStore {
			dbDir := cfg.WorkspacePath(userID)
			store, err := memory.GetMemoryStore(dbDir)
			if err != nil {
				slog.Warn("bootstrap: per-user memory store unavailable", "userID", userID, "err", err)
				return nil
			}
			return store
		})
		slog.Info("bootstrap: multi-user memory isolation enabled")
	}

	var vecStore *vector.Store
	var embedProv vector.EmbeddingProvider
	if gp, ok := prov.(*provider.GeminiProvider); ok && gp.Client() != nil {
		embedProv = vector.NewGeminiProvider(gp.Client())
		vsPath := filepath.Join(cfg.StorageRoot(), "memory", "vectors.db")
		vs, vsErr := vector.NewStore(vsPath)
		if vsErr != nil {
			slog.Warn("bootstrap: vector store unavailable", "err", vsErr)
		} else {
			vecStore = vs
			runner.vecStore = vs
			runner.embedProv = embedProv
			oldCleanup := cleanup
			cleanup = func() {
				oldCleanup()
				_ = vs.Save()
				_ = vs.Close()
			}
		}
	}

	runner.tools = registerTools(cfg, prov, model, memStore, vecStore, embedProv)

	return &agentStack{
		prov:      prov,
		model:     model,
		runner:    runner,
		memStore:  memStore,
		vecStore:  vecStore,
		embedProv: embedProv,
	}, cleanup, nil
}

// NewSessionManager initializes a new agent.SessionManager with standard gobot defaults.
// It ensures that all commands (run, simulate, cron) use consistent settings for
// timeouts, memory window, pruning, and compaction.
func (s *agentStack) NewSessionManager(cfg *config.Config, store agent.CheckpointStore, tracer *observability.DispatchTracer) *agent.SessionManager {
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

	// F-105: Wire per-user checkpoint store provider when multi-user isolation is enabled.
	if cfg.MultiUserEnabled() {
		mgr.SetCheckpointStoreProvider(func(userID string) (agent.CheckpointStore, error) {
			dbDir := cfg.WorkspacePath(userID)
			return agentctx.GetCheckpointManager(dbDir)
		})
		slog.Info("bootstrap: multi-user checkpoint isolation enabled")
	}

	return mgr
}
