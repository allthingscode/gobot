//nolint:testpackage // requires unexported factory internals for testing
package provider

import (
	"context"
	"testing"

	"github.com/allthingscode/gobot/internal/config"
)

const testRoutingProviderName = "routing"

type fakeProvider struct {
	name string
}

func (p fakeProvider) Name() string {
	return p.name
}

func (p fakeProvider) Chat(context.Context, ChatRequest) (*ChatResponse, error) {
	return &ChatResponse{}, nil
}

func (p fakeProvider) Models() []ModelInfo {
	return []ModelInfo{{ID: p.name + "-model"}}
}

func TestFactory_InitAll_Empty(t *testing.T) {
	t.Parallel()
	registry := NewRegistry()
	f := &Factory{Registry: registry}
	err := f.InitAll(context.Background(), nil)
	if err != nil {
		t.Fatalf("expected no error with empty config, got %v", err)
	}
}

func TestRegistry_RegisterGetList(t *testing.T) {
	t.Parallel()
	registry := NewRegistry()

	p1 := NewOpenAIProvider("key1", "url1")

	err := registry.Register(p1)
	if err != nil {
		t.Fatalf("Register failed: %v", err)
	}

	// Test Duplicate
	err = registry.Register(p1)
	if err == nil {
		t.Error("expected error when registering duplicate provider")
	}

	p2, err := registry.Get(providerNameOpenAI)
	if err != nil {
		t.Fatalf("Get failed: %v", err)
	}
	if p2.Name() != providerNameOpenAI {
		t.Errorf("got name %q", p2.Name())
	}

	_, err = registry.Get("not-exists")
	if err == nil {
		t.Error("expected error for non-existent provider")
	}

	list := registry.List()
	if len(list) != 1 || list[0] != providerNameOpenAI {
		t.Errorf("unexpected list: %v", list)
	}
}

func TestFactory_SetupRouting_RegistersRoutingProvider(t *testing.T) {
	t.Parallel()
	registry := NewRegistry()

	cfg := routingTestConfig("executor", "manager")
	if err := registry.Register(fakeProvider{name: "executor"}); err != nil {
		t.Fatalf("register executor: %v", err)
	}
	if err := registry.Register(fakeProvider{name: "manager"}); err != nil {
		t.Fatalf("register manager: %v", err)
	}

	err := (&Factory{Registry: registry}).setupRouting(cfg)
	if err != nil {
		t.Fatalf("setupRouting failed: %v", err)
	}

	p, err := registry.Get(testRoutingProviderName)
	if err != nil {
		t.Fatalf("routing provider was not registered: %v", err)
	}
	if p.Name() != testRoutingProviderName {
		t.Fatalf("routing provider name = %q, want %s", p.Name(), testRoutingProviderName)
	}
}

func TestFactory_SetupRouting_ManagerProviderDefaultsToExecutor(t *testing.T) {
	t.Parallel()
	registry := NewRegistry()

	cfg := routingTestConfig("executor", "")
	if err := registry.Register(fakeProvider{name: "executor"}); err != nil {
		t.Fatalf("register executor: %v", err)
	}

	err := (&Factory{Registry: registry}).setupRouting(cfg)
	if err != nil {
		t.Fatalf("setupRouting failed: %v", err)
	}

	p, err := registry.Get(testRoutingProviderName)
	if err != nil {
		t.Fatalf("routing provider was not registered: %v", err)
	}
	if p.Name() != testRoutingProviderName {
		t.Fatalf("routing provider name = %q, want %s", p.Name(), testRoutingProviderName)
	}
}

func TestFactory_SetupRouting_MissingExecutorErrors(t *testing.T) {
	t.Parallel()
	registry := NewRegistry()

	err := (&Factory{Registry: registry}).setupRouting(routingTestConfig("missing", "manager"))
	if err == nil {
		t.Fatal("setupRouting succeeded with missing executor provider")
	}
}

func TestFactory_InitAll_MissingRoutingExecutorContinues(t *testing.T) {
	t.Parallel()
	registry := NewRegistry()

	err := (&Factory{Registry: registry}).InitAll(context.Background(), routingTestConfig("missing", ""))
	if err != nil {
		t.Fatalf("InitAll returned error for missing routing executor: %v", err)
	}

	if _, err := registry.Get(testRoutingProviderName); err == nil {
		t.Fatal("routing provider was registered after setup failure")
	}
}

func TestFactory_InitAll_MissingRoutingManagerContinues(t *testing.T) {
	t.Parallel()
	registry := NewRegistry()

	if err := registry.Register(fakeProvider{name: "executor"}); err != nil {
		t.Fatalf("register executor: %v", err)
	}

	err := (&Factory{Registry: registry}).InitAll(context.Background(), routingTestConfig("executor", "missing-manager"))
	if err != nil {
		t.Fatalf("InitAll returned error for missing routing manager: %v", err)
	}

	if _, err := registry.Get(testRoutingProviderName); err == nil {
		t.Fatal("routing provider was registered after setup failure")
	}
}

func routingTestConfig(defaultProvider, managerProvider string) *config.Config {
	return &config.Config{
		Agents: config.AgentsConfig{
			Defaults: config.AgentDefaults{
				Provider: defaultProvider,
			},
		},
		Runtime: config.RuntimeConfig{
			Routing: config.RoutingConfig{
				Enabled:         true,
				ManagerModel:    "manager-model",
				ManagerProvider: managerProvider,
			},
		},
	}
}

//nolint:gocognit // Keep cross-owner setup and provider identity assertions together.
func TestFactory_IndependentRegistries(t *testing.T) {
	t.Parallel()
	factories := []*Factory{
		{OpenAIBaseURL: "http://127.0.0.1:1", AnthropicAPIKey: "dummy", GeminiAPIKey: "dummy", OpenRouterBaseURL: "http://127.0.0.1:2"},
		{Registry: NewRegistry(), OpenAIBaseURL: "http://127.0.0.1:3", AnthropicAPIKey: "dummy", GeminiAPIKey: "dummy", OpenRouterBaseURL: "http://127.0.0.1:4"},
	}
	supplied := factories[1].Registry
	for _, f := range factories {
		if err := f.InitAll(context.Background(), nil); err != nil {
			t.Fatal(err)
		}
		for _, name := range []string{"openai", "anthropic", "gemini", "openrouter"} {
			if _, err := f.Registry.Get(name); err != nil {
				t.Fatal(err)
			}
		}
		registry := f.Registry
		if err := f.InitAll(context.Background(), nil); err == nil {
			t.Fatal("repeat registration accepted")
		}
		if f.Registry != registry {
			t.Fatal("factory replaced its registry")
		}
	}
	if factories[1].Registry != supplied {
		t.Fatal("supplied registry replaced")
	}
	for _, name := range factories[0].Registry.List() {
		a, _ := factories[0].Registry.Get(name)
		b, _ := factories[1].Registry.Get(name)
		if a == b {
			t.Fatalf("shared provider %s", name)
		}
	}
}
