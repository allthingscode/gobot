package main

import (
	"context"
	"errors"
	"testing"

	"github.com/allthingscode/gobot/internal/agent"
	agentctx "github.com/allthingscode/gobot/internal/context"
)

// mockRunner is a test double for agent.Runner that returns a fixed response.
type mockRunner struct {
	response string
	err      error
	called   int
}

func (m *mockRunner) Run(_ context.Context, _ string, messages []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error) {
	m.called++
	if m.err != nil {
		return "", nil, m.err
	}
	text := m.response
	updated := append(messages, agentctx.StrategicMessage{
		Role:    "assistant",
		Content: &agentctx.MessageContent{Str: &text},
	})
	return m.response, updated, nil
}

// newTestSpawnTool builds a SpawnTool backed by a mockRunner factory.
func newTestSpawnTool(runner agent.Runner, prompts map[string]string) *SpawnTool {
	return &SpawnTool{
		runnerFactory: func(_ string) agent.Runner { return runner },
		model:         "test-model",
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

	if decl == nil {
		t.Fatal("Declaration() returned nil")
	}
	if decl.Name != spawnToolName {
		t.Errorf("Declaration.Name = %q, want %q", decl.Name, spawnToolName)
	}
	if decl.Description == "" {
		t.Error("Declaration.Description must not be empty")
	}
	if decl.Parameters == nil {
		t.Fatal("Declaration.Parameters is nil")
	}
	for _, req := range []string{"agent_type", "objective"} {
		if _, ok := decl.Parameters.Properties[req]; !ok {
			t.Errorf("Declaration.Parameters.Properties missing %q", req)
		}
	}
	// Both params must be in Required.
	requiredSet := make(map[string]bool, len(decl.Parameters.Required))
	for _, r := range decl.Parameters.Required {
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
				if tc.wantErrSubstr != "" && !contains(err.Error(), tc.wantErrSubstr) {
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
		runnerFactory: func(_ string) agent.Runner {
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

// captureKeyRunner captures the session key passed to Run.
type captureKeyRunner struct {
	capture *string
}

func (c *captureKeyRunner) Run(_ context.Context, sessionKey string, messages []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error) {
	*c.capture = sessionKey
	text := "captured"
	return text, append(messages, agentctx.StrategicMessage{
		Role:    "assistant",
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
		{"unknown_type", true},
		{"", true},
	}
	for _, tc := range tests {
		t.Run(tc.agentType, func(t *testing.T) {
			got := defaultSpecialistPrompt(tc.agentType)
			if tc.wantNonEmpty && got == "" {
				t.Errorf("defaultSpecialistPrompt(%q) returned empty string", tc.agentType)
			}
		})
	}
}

func contains(s, sub string) bool {
	return len(sub) == 0 || (len(s) >= len(sub) && func() bool {
		for i := 0; i <= len(s)-len(sub); i++ {
			if s[i:i+len(sub)] == sub {
				return true
			}
		}
		return false
	}())
}
