package main

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/agent"
	agentctx "github.com/allthingscode/gobot/internal/context"
)

// mockRunner implements agent.Runner for testing.
type mockRunner struct {
	called   int
	response string
	err      error
}

func (m *mockRunner) Run(_ context.Context, _ string, messages []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error) {
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
func newTestSpawnTool(runner agent.Runner, prompts map[string]string) *SpawnTool {
	return &SpawnTool{
		runnerFactory:     func(_, _ string) agent.Runner { return runner },
		model:             "test-model",
		specialistPrompts: prompts,
	}
}

// ── Name / Declaration ─────────────────────────────────────────────────────────

func TestSpawnTool_Name(t *testing.T) {
	tool := newTestSpawnTool(&mockRunner{response: "ok"}, nil)
	if tool.Name() != spawnToolName {
		t.Errorf("Name() = %q, want %q", tool.Name(), spawnToolName)
	}
}

func TestSpawnTool_Declaration(t *testing.T) {
	tool := newTestSpawnTool(&mockRunner{response: "ok"}, nil)
	decl := tool.Declaration()

	if decl.Name != spawnToolName {
		t.Errorf("Declaration.Name = %q, want %q", decl.Name, spawnToolName)
	}
	if decl.Description == "" {
		t.Error("Declaration.Description must not be empty")
	}
	if decl.Parameters == nil {
		t.Fatal("Declaration.Parameters is nil")
	}
	// Verify properties in the JSON Schema map
	props, _ := decl.Parameters["properties"].(map[string]any)
	for _, req := range []string{"agent_type", "objective"} {
		if _, ok := props[req]; !ok {
			t.Errorf("Declaration.Parameters properties missing %q", req)
		}
	}
	// Verify required fields
	reqs, _ := decl.Parameters["required"].([]string)
	requiredSet := make(map[string]bool, len(reqs))
	for _, r := range reqs {
		requiredSet[r] = true
	}
	for _, req := range []string{"agent_type", "objective"} {
		if !requiredSet[req] {
			t.Errorf("Required missing %q", req)
		}
	}
}

// ── Execute ────────────────────────────────────────────────────────────────────

func TestSpawnTool_Execute(t *testing.T) {
	tests := []struct {
		name          string
		args          map[string]any
		runnerResp    string
		runnerErr     error
		wantResult    string
		wantErr       bool
		wantErrSubstr string
	}{
		{
			name:       "normal dispatch returns sub-agent reply",
			args:       map[string]any{"agent_type": "researcher", "objective": "Summarize Go 1.22 release notes."},
			runnerResp: "Go 1.22 introduced range-over-int and improved loop variable scoping.",
			wantResult: "Go 1.22 introduced range-over-int and improved loop variable scoping.",
		},
		{
			name:       "defaults agent_type to researcher when missing",
			args:       map[string]any{"objective": "What is the capital of France?"},
			runnerResp: "Paris.",
			wantResult: "Paris.",
		},
		{
			name:          "empty objective returns error without calling runner",
			args:          map[string]any{"agent_type": "researcher", "objective": ""},
			wantErr:       true,
			wantErrSubstr: "objective is required",
		},
		{
			name:          "runner error is propagated",
			args:          map[string]any{"agent_type": "analyst", "objective": "Analyze sales data."},
			runnerErr:     errors.New("context deadline exceeded"),
			wantErr:       true,
			wantErrSubstr: "spawn analyst",
		},
		{
			name:       "custom specialist prompt is used",
			args:       map[string]any{"agent_type": "custom", "objective": "Do a custom thing."},
			runnerResp: "Custom response.",
			wantResult: "Custom response.",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			mock := &mockRunner{response: tc.runnerResp, err: tc.runnerErr}
			tool := newTestSpawnTool(mock, map[string]string{
				"custom": "You are a custom specialist.",
			})

			result, err := tool.Execute(context.Background(), "telegram:123", tc.args)
			if tc.wantErr {
				if err == nil {
					t.Fatal("Execute() expected error, got nil")
				}
				if tc.wantErrSubstr != "" && !strings.Contains(err.Error(), tc.wantErrSubstr) {
					t.Errorf("error %q does not contain %q", err.Error(), tc.wantErrSubstr)
				}
				return
			}
			if err != nil {
				t.Fatalf("Execute() unexpected error: %v", err)
			}
			if result != tc.wantResult {
				t.Errorf("result = %q, want %q", result, tc.wantResult)
			}
			// Runner must have been called exactly once.
			if tc.runnerErr == nil && mock.called != 1 {
				t.Errorf("runner called %d times, want 1", mock.called)
			}
		})
	}
}

func TestSpawnTool_SubAgentSessionKey(t *testing.T) {
	var capturedKey string
	tool := &SpawnTool{
		runnerFactory: func(_, _ string) agent.Runner {
			return &captureKeyRunner{capture: &capturedKey}
		},
		model: "test-model",
	}
	_, _ = tool.Execute(context.Background(), "telegram:999", map[string]any{
		"agent_type": "writer",
		"objective":  "Write a haiku.",
	})
	wantPrefix := "agent:writer:telegram:999"
	if capturedKey != wantPrefix {
		t.Errorf("sub-agent session key = %q, want %q", capturedKey, wantPrefix)
	}
}

func TestSpawnTool_SpecialistModelOverride(t *testing.T) {
	var capturedModel string
	tool := &SpawnTool{
		runnerFactory: func(model, _ string) agent.Runner {
			capturedModel = model
			return &mockRunner{response: "done"}
		},
		model: "default-model",
		specialistModels: map[string]string{
			"architect": "pro-model",
		},
	}
	_, err := tool.Execute(context.Background(), "parent:1", map[string]any{
		"agent_type": "architect",
		"objective":  "Design the system.",
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if capturedModel != "pro-model" {
		t.Errorf("want model %q, got %q", "pro-model", capturedModel)
	}
}

func TestSpawnTool_UnknownTypeUsesDefaultModel(t *testing.T) {
	var capturedModel string
	tool := &SpawnTool{
		runnerFactory: func(model, _ string) agent.Runner {
			capturedModel = model
			return &mockRunner{response: "done"}
		},
		model: "default-model",
		specialistModels: map[string]string{
			"architect": "pro-model",
		},
	}
	_, err := tool.Execute(context.Background(), "parent:1", map[string]any{
		"agent_type": "unknown-type",
		"objective":  "Do something.",
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if capturedModel != "default-model" {
		t.Errorf("want default model %q, got %q", "default-model", capturedModel)
	}
}

// captureKeyRunner captures the session key passed to Run.
type captureKeyRunner struct {
	capture *string
}

func (c *captureKeyRunner) RunText(_ context.Context, _, _, _ string) (string, error) { return "", nil }

func (c *captureKeyRunner) Run(_ context.Context, sessionKey string, messages []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error) {
	*c.capture = sessionKey
	text := "captured"
	return text, append(messages, agentctx.StrategicMessage{ //nolint:gocritic // intentional: return a new slice without mutating input
		Role:    agentctx.RoleAssistant,
		Content: &agentctx.MessageContent{Str: &text},
	}), nil
}

// ── defaultSpecialistPrompt ────────────────────────────────────────────────────

func TestDefaultSpecialistPrompt(t *testing.T) {
	tests := []struct {
		agentType    string
		wantNonEmpty bool
	}{
		{"researcher", true},
		{"analyst", true},
		{"writer", true},
	}
	for _, tc := range tests {
		t.Run(tc.agentType, func(t *testing.T) {
			p := defaultSpecialistPrompt(tc.agentType)
			if tc.wantNonEmpty && p == "" {
				t.Errorf("defaultSpecialistPrompt(%q) = %q, want non-empty", tc.agentType, p)
			}
		})
	}
}

func TestIterLimitRunner_StopsAtLimit(t *testing.T) {
	inner := &mockRunner{response: "ok"}
	limited := &iterLimitRunner{inner: inner, max: spawnMaxIterations}
	ctx := context.Background()

	// exhaust the limit
	for i := 0; i < spawnMaxIterations; i++ {
		limited.Run(ctx, "key", nil) //nolint:errcheck // exhaust limit in test
	}

	// next call must fail
	_, _, err := limited.Run(ctx, "key", nil)
	if err == nil {
		t.Fatal("expected error after max iterations, got nil")
	}
	wantSub := fmt.Sprintf("exceeded maximum iterations (%d)", spawnMaxIterations)
	if !strings.Contains(err.Error(), wantSub) {
		t.Errorf("error %q does not contain %q", err.Error(), wantSub)
	}
	// inner must NOT have been called on the failing iteration
	if inner.called != spawnMaxIterations {
		t.Errorf("inner.called = %d after limit, want %d", inner.called, spawnMaxIterations)
	}
}

func TestIterLimitRunner_CountTracked(t *testing.T) {
	inner := &mockRunner{response: "ok"}
	limited := &iterLimitRunner{inner: inner, max: 10}
	ctx := context.Background()

	for i := 0; i < 3; i++ {
		limited.Run(ctx, "key", nil) //nolint:errcheck // increment count in test
	}
	if limited.count != 3 {
		t.Errorf("count = %d, want 3", limited.count)
	}
}
