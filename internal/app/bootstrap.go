package app

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

// AgentStack holds the core components required to run the strategic agent.
type AgentStack struct {
	Prov      provider.Provider
	Model     string
	Runner    *AgentRunner
	MemStore  *memory.MemoryStore // may be nil; caller must defer cleanup() if non-nil
	VecStore  *vector.Store
	EmbedProv vector.EmbeddingProvider
}

// BuildAgentStack extracts the shared provider, system prompt, runner, and tool
// initialization sequence used by both 'run' and 'simulate' commands.
// Returns a stack of components and a cleanup function (to close memory store).
func BuildAgentStack(ctx context.Context, cfg *config.Config) (*AgentStack, func(), error) {
	prov, model, err := InitProviders(ctx, cfg)
	if err != nil {
		return nil, nil, err
	}

	EnsureAwarenessFile(cfg)
	systemPrompt := LoadSystemPrompt(cfg)
	if systemPrompt != "" {
		slog.Info("gobot: system prompt loaded", "bytes", len(systemPrompt))
	}

	runner := NewAgentRunner(prov, model, systemPrompt, cfg)
	memStore, cleanup := InitMemory(cfg, runner)
	vecStore, embedProv, vecCleanup := InitVectorStore(cfg, prov, runner)

	runner.SetTools(RegisterTools(cfg, prov, model, memStore, vecStore, embedProv))

	finalCleanup := func() {
		cleanup()
		vecCleanup()
	}

	return &AgentStack{
		Prov:      prov,
		Model:     model,
		Runner:    runner,
		MemStore:  memStore,
		VecStore:  vecStore,
		EmbedProv: embedProv,
	}, finalCleanup, nil
}

// InitProviders initializes all configured LLM providers and returns the default provider and model.
func InitProviders(ctx context.Context, cfg *config.Config) (provider.Provider, string, error) {
	factory := &provider.Factory{
		GeminiAPIKey:    cfg.GeminiAPIKey(),
		AnthropicAPIKey: cfg.AnthropicAPIKey(),
		OpenAIAPIKey:    cfg.OpenAIAPIKey(),
		OpenAIBaseURL:   cfg.OpenAIBaseURL(),
	}
	if err := factory.InitAll(ctx); err != nil {
		return nil, "", err
	}

	provName := cfg.DefaultProvider()
	prov, err := provider.Get(provName)
	if err != nil {
		return nil, "", fmt.Errorf("provider: %w", err)
	}
	model := cfg.DefaultModel()

	if cfg.Strategic.Routing.Enabled {
		prov = wrapRoutingProvider(prov, provName, cfg)
	}
	return prov, model, nil
}

func wrapRoutingProvider(base provider.Provider, provName string, cfg *config.Config) provider.Provider {
	mgrProvName := cfg.Strategic.Routing.ManagerProvider
	if mgrProvName == "" {
		mgrProvName = provName
	}
	mgrProv, err := provider.Get(mgrProvName)
	if err != nil {
		slog.Warn("bootstrap: manager provider not found, disabling cost routing", "provider", mgrProvName)
		return base
	}
	slog.Info("bootstrap: cost routing enabled", "manager_model", cfg.Strategic.Routing.ManagerModel, "manager_provider", mgrProvName)
	return provider.NewRoutingProvider(base, mgrProv, cfg.Strategic.Routing)
}

// InitMemory initializes the long-term memory store and configures multi-user isolation if enabled.
func InitMemory(cfg *config.Config, runner *AgentRunner) (memStore *memory.MemoryStore, cleanup func()) {
	cleanup = func() {}
	memStore, err := memory.NewMemoryStore(cfg.StorageRoot())
	if err != nil {
		slog.Warn("bootstrap: memory store unavailable, running without long-term memory", "err", err)
	} else if memStore != nil {
		runner.MemStore = memStore
		cleanup = func() { _ = memStore.Close() }
	}

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
	return memStore, cleanup
}

// InitVectorStore initializes the semantic vector store and embedding provider.
func InitVectorStore(cfg *config.Config, prov provider.Provider, runner *AgentRunner) (*vector.Store, vector.EmbeddingProvider, func()) {
	cleanup := func() {}
	var vecStore *vector.Store
	var embedProv vector.EmbeddingProvider

	gp, ok := prov.(*provider.GeminiProvider)
	if !ok || gp.Client() == nil {
		return nil, nil, cleanup
	}

	embedProv = vector.NewGeminiProvider(gp.Client(), cfg.EmbeddingModel())
	vsPath := filepath.Join(cfg.StorageRoot(), "memory", "vectors.db")
	vs, err := vector.NewStore(vsPath)
	if err != nil {
		slog.Warn("bootstrap: vector store unavailable", "err", err)
		return nil, nil, cleanup
	}

	vecStore = vs
	runner.VecStore = vs
	runner.EmbedProv = embedProv
	cleanup = func() {
		_ = vs.Save()
		_ = vs.Close()
	}
	return vecStore, embedProv, cleanup
}

// NewSessionManager initializes a new agent.SessionManager with standard gobot defaults.
// It ensures that all commands (run, simulate, cron) use consistent settings for
// timeouts, memory window, pruning, and compaction.
func (s *AgentStack) NewSessionManager(cfg *config.Config, store agent.CheckpointStore, tracer *observability.DispatchTracer) *agent.SessionManager {
	mgr := agent.NewSessionManager(agent.Runner(s.Runner), store, s.Model)

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
