//nolint:testpackage // intentionally uses unexported helpers from main package
package app

import (
	"context"
	"testing"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/provider"
)

type mockSubAgentRunner struct {
	response string
	err      error
}

func (m *mockSubAgentRunner) RunText(_ context.Context, _, _, _ string) (string, error) {
	return m.response, m.err
}

func (m *mockSubAgentRunner) SetMaxToolIterations(_ int) {}

func (m *mockSubAgentRunner) Run(_ context.Context, _, _ string, _ []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error) {
	return m.response, nil, m.err
}

func TestSpawnTool_Name(t *testing.T) {
	t.Parallel()
	tool := &SpawnTool{}
	if tool.Name() != "spawn_subagent" {
		t.Errorf("Name() = %q, want 'spawn_subagent'", tool.Name())
	}
}

func TestSpawnTool_Declaration(t *testing.T) {
	t.Parallel()
	tool := &SpawnTool{}
	decl := tool.Declaration()
	if decl.Name != "spawn_subagent" {
		t.Errorf("Declaration.Name = %q, want 'spawn_subagent'", decl.Name)
	}
}

func TestSpawnTool_Execute_Success(t *testing.T) {
	t.Parallel()
	runner := &mockSubAgentRunner{response: "Hello from sub-agent"}
	tool := &SpawnTool{
		RunnerFactory: func(_ provider.Provider, _, _ string) agent.Runner {
			return runner
		},
		Model: "test-model",
	}

	got, err := tool.Execute(context.Background(), "sess", "user", map[string]any{
		"objective": "say hello",
	})
	if err != nil {
		t.Fatalf("Execute failed: %v", err)
	}
	if got != "Hello from sub-agent" {
		t.Errorf("Execute got %q, want %q", got, "Hello from sub-agent")
	}
}

func TestSpawnTool_Execute_Error(t *testing.T) {
	t.Parallel()
	// Test with missing 'objective' parameter
	tool := &SpawnTool{}
	_, err := tool.Execute(context.Background(), "sess", "user", map[string]any{})
	if err == nil {
		t.Error("expected error for missing objective parameter, got nil")
	}
}

// TestSpawnTool_Execute_UsesSpecialistProvider ensures that when a specialist has
// an explicit provider configured, Execute routes to that provider rather than
// the parent agent's default provider. Regression for the bug where all sub-agents
// were always dispatched through the parent provider (e.g. Gemini receiving an
// OpenRouter-only model, causing 404s).
func TestSpawnTool_Execute_UsesSpecialistProvider(t *testing.T) { //nolint:paralleltest // modifies global provider registry
	const defaultProvName = "default-prov"
	const specialistProvName = "specialist-prov"

	defaultProv := &mockNamedProvider{name: defaultProvName}
	specialistProv := &mockNamedProvider{name: specialistProvName}

	provider.ResetForTest()
	t.Cleanup(provider.ResetForTest)
	if err := provider.Register(defaultProv); err != nil {
		t.Fatalf("register default provider: %v", err)
	}
	if err := provider.Register(specialistProv); err != nil {
		t.Fatalf("register specialist provider: %v", err)
	}

	cfg := &config.Config{
		Agents: config.AgentsConfig{
			Specialists: map[string]config.SpecialistConfig{
				RoleResearcher: {Model: "specialist-model", Provider: specialistProvName},
			},
		},
	}

	var capturedProv provider.Provider
	tool := &SpawnTool{
		RunnerFactory: func(prov provider.Provider, _, _ string) agent.Runner {
			capturedProv = prov
			return &mockSubAgentRunner{response: "ok"}
		},
		DefaultProv:      defaultProv,
		Model:            "default-model",
		SpecialistModels: map[string]string{RoleResearcher: "specialist-model"},
		Cfg:              cfg,
	}

	_, err := tool.Execute(context.Background(), "sess", "user", map[string]any{
		"agent_type": RoleResearcher,
		"objective":  "research something",
	})
	if err != nil {
		t.Fatalf("Execute failed: %v", err)
	}

	if capturedProv != specialistProv {
		t.Errorf("RunnerFactory received provider %q, want %q", capturedProv.Name(), specialistProvName)
	}
}

// mockNamedProvider is a minimal Provider that returns a fixed name.
type mockNamedProvider struct {
	provider.Provider
	name string
}

func (m *mockNamedProvider) Name() string { return m.name }
func (m *mockNamedProvider) Chat(_ context.Context, _ provider.ChatRequest) (*provider.ChatResponse, error) {
	resp := "ok"
	return &provider.ChatResponse{
		Message: agentctx.StrategicMessage{
			Role:    agentctx.RoleAssistant,
			Content: &agentctx.MessageContent{Str: &resp},
		},
	}, nil
}

func TestDefaultSpecialistPrompt(t *testing.T) {
	t.Parallel()
	tests := []string{RoleResearcher, RoleAnalyst, RoleWriter, "unknown"}
	for _, tt := range tests {
		got := DefaultSpecialistPrompt(tt)
		if got == "" {
			t.Errorf("DefaultSpecialistPrompt(%q) returned empty string", tt)
		}
	}
}
