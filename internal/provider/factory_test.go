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

func TestFactory_InitAll_Empty(t *testing.T) { //nolint:paralleltest // mutates global registry; must not run in parallel
	t.Cleanup(ResetForTest)
	f := &Factory{}
	err := f.InitAll(context.Background(), nil)
	if err != nil {
		t.Fatalf("expected no error with empty config, got %v", err)
	}
}

func TestRegistry_RegisterGetList(t *testing.T) { //nolint:paralleltest // mutates global registry; must not run in parallel
	t.Cleanup(ResetForTest)

	p1 := NewOpenAIProvider("key1", "url1")

	err := Register(p1)
	if err != nil {
		t.Fatalf("Register failed: %v", err)
	}

	// Test Duplicate
	err = Register(p1)
	if err == nil {
		t.Error("expected error when registering duplicate provider")
	}

	p2, err := Get(providerNameOpenAI)
	if err != nil {
		t.Fatalf("Get failed: %v", err)
	}
	if p2.Name() != providerNameOpenAI {
		t.Errorf("got name %q", p2.Name())
	}

	_, err = Get("not-exists")
	if err == nil {
		t.Error("expected error for non-existent provider")
	}

	list := List()
	if len(list) != 1 || list[0] != providerNameOpenAI {
		t.Errorf("unexpected list: %v", list)
	}
}

func TestFactory_SetupRouting_RegistersRoutingProvider(t *testing.T) { //nolint:paralleltest // mutates global registry; must not run in parallel
	t.Cleanup(ResetForTest)

	cfg := routingTestConfig("executor", "manager")
	if err := Register(fakeProvider{name: "executor"}); err != nil {
		t.Fatalf("register executor: %v", err)
	}
	if err := Register(fakeProvider{name: "manager"}); err != nil {
		t.Fatalf("register manager: %v", err)
	}

	err := (&Factory{}).setupRouting(cfg)
	if err != nil {
		t.Fatalf("setupRouting failed: %v", err)
	}

	p, err := Get(testRoutingProviderName)
	if err != nil {
		t.Fatalf("routing provider was not registered: %v", err)
	}
	if p.Name() != testRoutingProviderName {
		t.Fatalf("routing provider name = %q, want %s", p.Name(), testRoutingProviderName)
	}
}

func TestFactory_SetupRouting_ManagerProviderDefaultsToExecutor(t *testing.T) { //nolint:paralleltest // mutates global registry; must not run in parallel
	t.Cleanup(ResetForTest)

	cfg := routingTestConfig("executor", "")
	if err := Register(fakeProvider{name: "executor"}); err != nil {
		t.Fatalf("register executor: %v", err)
	}

	err := (&Factory{}).setupRouting(cfg)
	if err != nil {
		t.Fatalf("setupRouting failed: %v", err)
	}

	p, err := Get(testRoutingProviderName)
	if err != nil {
		t.Fatalf("routing provider was not registered: %v", err)
	}
	if p.Name() != testRoutingProviderName {
		t.Fatalf("routing provider name = %q, want %s", p.Name(), testRoutingProviderName)
	}
}

func TestFactory_SetupRouting_MissingExecutorErrors(t *testing.T) { //nolint:paralleltest // mutates global registry; must not run in parallel
	t.Cleanup(ResetForTest)

	err := (&Factory{}).setupRouting(routingTestConfig("missing", "manager"))
	if err == nil {
		t.Fatal("setupRouting succeeded with missing executor provider")
	}
}

func TestFactory_InitAll_MissingRoutingExecutorContinues(t *testing.T) { //nolint:paralleltest // mutates global registry; must not run in parallel
	t.Cleanup(ResetForTest)

	err := (&Factory{}).InitAll(context.Background(), routingTestConfig("missing", ""))
	if err != nil {
		t.Fatalf("InitAll returned error for missing routing executor: %v", err)
	}

	if _, err := Get(testRoutingProviderName); err == nil {
		t.Fatal("routing provider was registered after setup failure")
	}
}

func TestFactory_InitAll_MissingRoutingManagerContinues(t *testing.T) { //nolint:paralleltest // mutates global registry; must not run in parallel
	t.Cleanup(ResetForTest)

	if err := Register(fakeProvider{name: "executor"}); err != nil {
		t.Fatalf("register executor: %v", err)
	}

	err := (&Factory{}).InitAll(context.Background(), routingTestConfig("executor", "missing-manager"))
	if err != nil {
		t.Fatalf("InitAll returned error for missing routing manager: %v", err)
	}

	if _, err := Get(testRoutingProviderName); err == nil {
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
