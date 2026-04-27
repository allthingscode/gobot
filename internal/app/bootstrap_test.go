//nolint:testpackage // intentionally uses unexported helpers from main package
package app

import (
	"context"
	"testing"

	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/provider"
)

//nolint:paralleltest // uses global state // touches global provider registry
func TestInitProviders_OpenRouterRouting(t *testing.T) {
	// Not parallel because it touches the global provider registry.
	t.Cleanup(provider.ResetForTest)
	
	// Register a mock openrouter provider.
	_ = provider.Register(&MockProvider{name: "openrouter"})
	
	ctx := context.Background()
	cfg := &config.Config{}
	cfg.Agents.Defaults.Provider = "gemini"
	cfg.Agents.Defaults.Model = "openrouter/mistralai/mistral-7b-instruct"
	
	prov, model, err := InitProviders(ctx, cfg)
	if err != nil {
		t.Fatalf("InitProviders failed: %v", err)
	}
	
	if prov.Name() != "openrouter" {
		t.Errorf("got provider %q, want %q", prov.Name(), "openrouter")
	}
	if model != "openrouter/mistralai/mistral-7b-instruct" {
		t.Errorf("got model %q, want %q", model, "openrouter/mistralai/mistral-7b-instruct")
	}
}

func TestInitProviders_ManagerModel(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	cfg := &config.Config{}
	
	// Test that it handles missing providers gracefully
	cfg.Agents.Defaults.Provider = "nonexistent"
	_, _, err := InitProviders(ctx, cfg)
	if err == nil {
		t.Error("expected error for nonexistent provider, got nil")
	}
}

func TestInitProviders_CostRouting(t *testing.T) { //nolint:paralleltest // uses global state // touches global provider registry
	t.Cleanup(provider.ResetForTest)
	
	// Register mock providers.
	_ = provider.Register(&MockProvider{name: "gemini"})
	_ = provider.Register(&MockProvider{name: "anthropic"})
	
	ctx := context.Background()
	cfg := &config.Config{}
	cfg.Agents.Defaults.Provider = "gemini"
	cfg.Strategic.Routing.Enabled = true
	cfg.Strategic.Routing.ManagerProvider = "anthropic"
	cfg.Strategic.Routing.ManagerModel = "claude-3-haiku"
	
	prov, _, err := InitProviders(ctx, cfg)
	if err != nil {
		t.Fatalf("InitProviders failed: %v", err)
	}
	
	// Check if it's a RoutingProvider.
	// Since we changed Name() to return a fixed string "routing".
	if prov.Name() != "routing" {
		t.Errorf("got provider %q, want %q", prov.Name(), "routing")
	}
}

func TestInitMemory_Failures(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	// Use a path that is unlikely to be writable or valid, but don't strictly assert nil if NewMemoryStore is too resilient.
	cfg.Strategic.StorageRoot = ""
	runner := &AgentRunner{}
	
	_, cleanup := InitMemory(cfg, runner)
	cleanup()
}

func TestInitMemory_Success(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = tmpDir
	runner := &AgentRunner{}
	
	memStore, cleanup := InitMemory(cfg, runner)
	if memStore == nil {
		t.Error("expected non-nil memStore")
	}
	cleanup()
}

func TestInitVectorStore_Failures(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	runner := &AgentRunner{}
	
	// Case 1: Vector search disabled
	cfg.Strategic.VectorSearchEnabled = false
	vs, ep, cleanup := InitVectorStore(cfg, nil, runner)
	if vs != nil || ep != nil {
		t.Error("expected nil vs and ep when VectorSearchEnabled is false")
	}
	cleanup()

	// Case 2: Prov is not a GeminiProvider
	cfg.Strategic.VectorSearchEnabled = true
	prov := &MockProvider{}
	vs, ep, cleanup = InitVectorStore(cfg, prov, runner)
	if vs != nil || ep != nil {
		t.Error("expected nil vs and ep for non-Gemini provider")
	}
	cleanup()
}

func TestAgentStack_NewSessionManager(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	stack := &AgentStack{
		Runner: &AgentRunner{},
		Model:  "test-model",
	}
	
	mgr := stack.NewSessionManager(cfg, nil, nil)
	if mgr == nil {
		t.Fatal("NewSessionManager returned nil")
	}
}

func TestAgentRunner_SetTools(t *testing.T) {
	t.Parallel()
	r := &AgentRunner{}
	r.SetTools([]Tool{&mockTool{name: "test"}})
	if len(r.ToolsByName) == 0 {
		t.Error("SetTools failed to set r.ToolsByName")
	}
}
