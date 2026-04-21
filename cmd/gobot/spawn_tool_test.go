//nolint:testpackage // intentionally uses unexported helpers from main package
package main

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/app"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/provider"
)

// mockRunner implements agent.Runner for testing.
type mockRunner struct {
	called   int
	response string
	err      error
}

func (m *mockRunner) Run(_ context.Context, _, _ string, messages []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error) {
	m.called++
	if m.err != nil {
		return "", nil, m.err
	}
	text := m.response
	updated := append(messages, agentctx.StrategicMessage{ //nolint:gocritic // intentional: return a new slice without mutating input
		Role:    agentctx.RoleAssistant,
		Content: &agentctx.MessageContent{Str: &text},
	})
	return m.response, updated, nil
}

func (m *mockRunner) RunText(_ context.Context, _, _, _ string) (string, error) {
	return m.response, m.err
}

// newTestSpawnTool builds a SpawnTool backed by a mockRunner factory.
func newTestSpawnTool(runner agent.Runner, prompts map[string]string) *app.SpawnTool {
	return &app.SpawnTool{
		RunnerFactory:     func(_ provider.Provider, _, _ string) agent.Runner { return runner },
		Model:             "test-model",
		SpecialistPrompts: prompts,
	}
}

// ── Name / Declaration ────────────────────────────────────────────────────────

func TestSpawnTool_Name(t *testing.T) {
	t.Parallel()
	st := &app.SpawnTool{}
	if st.Name() != "spawn_subagent" {
		t.Errorf("Name() = %q, want 'spawn_subagent'", st.Name())
	}
}

func TestSpawnTool_Declaration(t *testing.T) {
	t.Parallel()
	st := &app.SpawnTool{}
	decl := st.Declaration()
	if decl.Name != "spawn_subagent" {
		t.Errorf("Declaration.Name = %q, want 'spawn_subagent'", decl.Name)
	}
	if len(decl.Parameters) != 3 {
		t.Errorf("expected 3 parameters, got %d", len(decl.Parameters))
	}
}

// ── Execution / Happy Path ───────────────────────────────────────────────────

func TestSpawnTool_Execute_Success(t *testing.T) {
	t.Parallel()
	mock := &mockRunner{response: "This is the research summary."}
	st := newTestSpawnTool(mock, nil)

	ctx := context.Background()
	args := map[string]any{
		"agent_type": "researcher",
		"objective":  "Research the history of Go.",
	}

	reply, err := st.Execute(ctx, "parent-session", "user-123", args)
	if err != nil {
		t.Fatalf("Execute() failed: %v", err)
	}

	if reply != mock.response {
		t.Errorf("Execute() reply = %q, want %q", reply, mock.response)
	}
	if mock.called != 1 {
		t.Errorf("mock runner called %d times, want 1", mock.called)
	}
}

func TestSpawnTool_Execute_SpecialistPrompt(t *testing.T) {
	t.Parallel()
	// Verification logic: ensure the factory is called with our custom prompt.
	var capturedPrompt string
	st := &app.SpawnTool{
		RunnerFactory: func(_ provider.Provider, _, sys string) agent.Runner {
			capturedPrompt = sys
			return &mockRunner{response: "ok"}
		},
		SpecialistPrompts: map[string]string{
			"researcher": "Custom research prompt",
		},
	}

	args := map[string]any{"agent_type": "researcher", "objective": "task"}
	_, _ = st.Execute(context.Background(), "s", "u", args)

	if capturedPrompt != "Custom research prompt" {
		t.Errorf("captured prompt = %q, want 'Custom research prompt'", capturedPrompt)
	}
}

// ── Validation / Errors ──────────────────────────────────────────────────────

func TestSpawnTool_Execute_RequiresObjective(t *testing.T) {
	t.Parallel()
	st := &app.SpawnTool{}
	args := map[string]any{"agent_type": "researcher"} // missing objective

	_, err := st.Execute(context.Background(), "s", "u", args)
	if err == nil {
		t.Error("expected error for missing objective, got nil")
	}
	if !strings.Contains(err.Error(), "objective is required") {
		t.Errorf("error %q does not contain 'objective is required'", err)
	}
}

func TestSpawnTool_Execute_RunnerError(t *testing.T) {
	t.Parallel()
	mockErr := errors.New("provider failure")
	mock := &mockRunner{err: mockErr}
	st := newTestSpawnTool(mock, nil)

	args := map[string]any{"objective": "task"}
	_, err := st.Execute(context.Background(), "s", "u", args)

	if err == nil {
		t.Fatal("expected error from runner, got nil")
	}
	if !errors.Is(err, mockErr) {
		t.Errorf("error = %v, want wrapper for %v", err, mockErr)
	}
}

func TestSpawnTool_Execute_DefaultSpecialist(t *testing.T) {
	t.Parallel()
	st := newTestSpawnTool(&mockRunner{response: "ok"}, nil)
	args := map[string]any{"objective": "task"} // missing agent_type

	// Should fallback to researcher
	_, err := st.Execute(context.Background(), "s", "u", args)
	if err != nil {
		t.Errorf("Execute() with missing agent_type failed: %v", err)
	}
}
