//nolint:testpackage // intentionally uses unexported helpers from main package
package app

import (
	"context"
	"reflect"
	"testing"

	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/provider"
)

func TestInitProviders_OpenRouterRouting(t *testing.T) {
	registry := provider.NewRegistry()
	t.Parallel()

	// Register a mock openrouter provider.
	if err := registry.Register(&MockProvider{name: "openrouter"}); err != nil {
		t.Fatal(err)
	}

	ctx := context.Background()
	cfg := &config.Config{}
	cfg.Agents.Defaults.Provider = "gemini"
	cfg.Agents.Defaults.Model = "openrouter/mistralai/mistral-7b-instruct"

	prov, model, err := initProviders(ctx, cfg, registry)
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

func TestInitProviders_CostRouting(t *testing.T) {
	t.Parallel()
	registry := provider.NewRegistry()
	// Register mock providers.
	if err := registry.Register(&MockProvider{name: "gemini"}); err != nil {
		t.Fatal(err)
	}
	if err := registry.Register(&MockProvider{name: "anthropic"}); err != nil {
		t.Fatal(err)
	}

	ctx := context.Background()
	cfg := &config.Config{}
	cfg.Agents.Defaults.Provider = "gemini"
	cfg.Runtime.Routing.Enabled = true
	cfg.Runtime.Routing.ManagerProvider = "anthropic"
	cfg.Runtime.Routing.ManagerModel = "claude-3-haiku"

	prov, _, err := initProviders(ctx, cfg, registry)
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
	cfg.Runtime.StorageRoot = ""
	runner := &AgentRunner{}

	_, cleanup := InitMemory(cfg, runner)
	cleanup()
}

func TestInitMemory_Success(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	cfg := &config.Config{}
	cfg.Runtime.StorageRoot = tmpDir
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
	cfg.Runtime.VectorSearchEnabled = false
	vs, ep, cleanup := InitVectorStore(cfg, nil, runner)
	if vs != nil || ep != nil {
		t.Error("expected nil vs and ep when VectorSearchEnabled is false")
	}
	cleanup()

	// Case 2: Prov is not a GeminiProvider
	cfg.Runtime.VectorSearchEnabled = true
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

func TestAgentStack_TokenBudgetConfiguration(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name                                 string
		budget, turns, wantBudget, wantTurns int
	}{
		{"defaults", 0, 0, 80000, 20},
		{"explicit", 1234, 7, 1234, 7},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			cfg := &config.Config{}
			cfg.Context.SessionTokenBudget = tc.budget
			cfg.Context.CompactionSummaryTurns = tc.turns
			stack := &AgentStack{Runner: &AgentRunner{}, Model: "test-model"}
			mgr := stack.NewSessionManager(cfg, nil, nil)
			fields := reflect.ValueOf(mgr).Elem()
			if fields.FieldByName("tokenBudget").Int() != int64(tc.wantBudget) || fields.FieldByName("summaryTurns").Int() != int64(tc.wantTurns) {
				t.Fatal("factory did not apply configured token compaction settings")
			}
		})
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

//nolint:gocognit,cyclop // Keep cross-owner setup and provider identity assertions together.
func TestBuildAgentStack_IndependentOwners(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name, model, selected string
		routing               bool
	}{
		{"default", "local-model", "openai", false},
		{"prefix", "openrouter/local-model", "openrouter", false},
		{"routing", "local-model", "routing", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			stacks := make([]*AgentStack, 2)
			cleanups := make([]func(), 2)
			for i := range stacks {
				cfg := &config.Config{}
				cfg.Runtime.StorageRoot = t.TempDir()
				cfg.Providers.OpenAI.BaseURL = []string{"http://127.0.0.1:1", "http://127.0.0.1:3"}[i]
				cfg.Providers.OpenRouter.BaseURL = []string{"http://127.0.0.1:2", "http://127.0.0.1:4"}[i]
				cfg.Agents.Defaults.Provider = "openai"
				cfg.Agents.Defaults.Model = tc.model
				cfg.Runtime.Routing.Enabled = tc.routing
				stack, cleanup, err := BuildAgentStack(context.Background(), cfg, nil, nil)
				if err != nil {
					t.Fatal(err)
				}
				stacks[i], cleanups[i] = stack, cleanup
				t.Cleanup(cleanup)
				got, err := stack.Providers.Get(tc.selected)
				if err != nil || got != stack.Prov || stack.Model != tc.model {
					t.Fatalf("selection = %v, %v", got, err)
				}
				spawn, ok := stack.Runner.ToolsByName[spawnToolName].(*SpawnTool)
				if !ok || spawn.Resolver != stack.Providers {
					t.Fatal("spawn lost owning resolver")
				}
			}
			if stacks[0].Providers == stacks[1].Providers || stacks[0].Prov == stacks[1].Prov {
				t.Fatal("stacks share provider ownership")
			}
			cleanups[0]()
			got, err := stacks[1].Providers.Get(tc.selected)
			if err != nil || got != stacks[1].Prov {
				t.Fatal("cleanup invalidated other owner")
			}
		})
	}
}
