//nolint:testpackage // intentionally uses unexported helpers from main package
package app

import (
	"context"
	"testing"

	"github.com/allthingscode/gobot/internal/agent"
	agentctx "github.com/allthingscode/gobot/internal/context"
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
		RunnerFactory: func(m, sp string) agent.Runner {
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
