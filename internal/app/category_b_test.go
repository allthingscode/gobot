package app_test

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/app"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/provider"
)

func strPtr(s string) *string { return &s }

func TestRunner_CategoryB_ContextCanceled(t *testing.T) {
	t.Parallel()
	name := "test_tool"
	
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // Cancel context immediately

	mock := &app.MockProvider{
		Responses: []*provider.ChatResponse{
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
	runner := app.NewAgentRunner(mock, "model", "sys", cfg)
	runner.SetTools([]app.Tool{&categoryBMockTool{name: name}})

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

	mock := &app.MockProvider{
		Responses: []*provider.ChatResponse{
			{
				Message: agentctx.StrategicMessage{
					Role: agentctx.RoleAssistant,
					ToolCalls: []agentctx.ToolCall{
						{Name: name, Args: map[string]any{"x": 1}},
					},
				},
			},
			{
				Message: agentctx.StrategicMessage{
					Role:    agentctx.RoleAssistant,
					Content: &agentctx.MessageContent{Str: strPtr("done")},
				},
			},
		},
	}

	cfg := &config.Config{}
	runner := app.NewAgentRunner(mock, "model", "sys", cfg)
	// No tools registered

	_, messages, err := runner.Run(context.Background(), "session", "user", nil)
	if err != nil {
		t.Fatalf("expected Category A handling (no error), got %v", err)
	}

	// messages should contain:
	// 1. Assistant tool call
	// 2. Tool response (Category A error)
	// 3. Assistant "done"
	if len(messages) < 2 {
		t.Fatalf("expected at least 2 messages in history, got %d", len(messages))
	}
	toolResp := messages[1]
	if toolResp.Role != agentctx.RoleTool {
		t.Errorf("expected RoleTool for message 1, got %v", toolResp.Role)
	}
	if toolResp.Content == nil || toolResp.Content.Str == nil || !strings.Contains(*toolResp.Content.Str, "unknown tool") {
		t.Errorf("expected 'unknown tool' in tool response content, got %v", toolResp.Content)
	}
}

func TestRunner_CategoryB_PolicyDenied(t *testing.T) {
	t.Parallel()
	name := "denied_tool"

	mock := &app.MockProvider{
		Responses: []*provider.ChatResponse{
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
	runner := app.NewAgentRunner(mock, "model", "sys", cfg)
	runner.SetTools([]app.Tool{&categoryBMockTool{name: name}})
	
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
