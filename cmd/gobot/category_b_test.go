package main

import (
	"context"
	"errors"
	"fmt"
	"testing"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/provider"
)

func TestRunner_CategoryB_ContextCanceled(t *testing.T) {
	t.Parallel()
	name := "test_tool"
	
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // Cancel context immediately

	mock := &mockProvider{
		responses: []*provider.ChatResponse{
			{
				Message: agentctx.StrategicMessage{
					Role: agentctx.RoleAssistant,
					ToolCalls: []agentctx.ToolCall{
						{Name: name, Args: map[string]any{"x": 1}},
					},
				},
			},
		},
	}

	cfg := &config.Config{}
	runner := newGeminiRunner(mock, "model", "sys", cfg)
	runner.SetTools([]Tool{&categoryBMockTool{name: name}})

	_, _, err := runner.Run(ctx, "session", "user", nil)
	if err == nil {
		t.Fatal("expected error from canceled context, got nil")
	}
	if !errors.Is(err, context.Canceled) {
		t.Errorf("expected error context.Canceled, got %v", err)
	}
}

func TestRunner_CategoryB_UnknownTool(t *testing.T) {
	t.Parallel()
	name := "unknown_tool"

	mock := &mockProvider{
		responses: []*provider.ChatResponse{
			{
				Message: agentctx.StrategicMessage{
					Role: agentctx.RoleAssistant,
					ToolCalls: []agentctx.ToolCall{
						{Name: name, Args: map[string]any{"x": 1}},
					},
				},
			},
		},
	}

	cfg := &config.Config{}
	runner := newGeminiRunner(mock, "model", "sys", cfg)
	// No tools registered

	_, _, err := runner.Run(context.Background(), "session", "user", nil)
	if err == nil {
		t.Fatal("expected error from unknown tool, got nil")
	}
	if !errors.Is(err, agent.ErrUnknownTool) {
		t.Errorf("expected error agent.ErrUnknownTool, got %v", err)
	}
}

func TestRunner_CategoryB_PolicyDenied(t *testing.T) {
	t.Parallel()
	name := "denied_tool"

	mock := &mockProvider{
		responses: []*provider.ChatResponse{
			{
				Message: agentctx.StrategicMessage{
					Role: agentctx.RoleAssistant,
					ToolCalls: []agentctx.ToolCall{
						{Name: name, Args: map[string]any{"x": 1}},
					},
				},
			},
		},
	}

	cfg := &config.Config{}
	runner := newGeminiRunner(mock, "model", "sys", cfg)
	runner.SetTools([]Tool{&categoryBMockTool{name: name}})
	
	// Add a hook that returns ErrToolDenied
	hooks := &agent.Hooks{}
	hooks.RegisterPreTool(func(ctx context.Context, sessionKey, toolName string, args map[string]any) (string, error) {
		if toolName == name {
			return "", fmt.Errorf("%w: policy denied", agent.ErrToolDenied)
		}
		return "", nil
	})
	runner.SetHooks(hooks)

	_, _, err := runner.Run(context.Background(), "session", "user", nil)
	if err == nil {
		t.Fatal("expected error from denied tool, got nil")
	}
	if !errors.Is(err, agent.ErrToolDenied) {
		t.Errorf("expected error agent.ErrToolDenied, got %v", err)
	}
}

type categoryBMockTool struct {
	name string
}

func (m *categoryBMockTool) Name() string                        { return m.name }
func (m *categoryBMockTool) Declaration() provider.ToolDeclaration { return provider.ToolDeclaration{Name: m.name} }
func (m *categoryBMockTool) Execute(_ context.Context, _, _ string, _ map[string]any) (string, error) {
	return "ok", nil
}
