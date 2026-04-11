package provider_test

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/provider"
)

type MockProvider struct {
	name     string
	chatFunc func(req provider.ChatRequest) (*provider.ChatResponse, error)
}

func (m *MockProvider) Name() string { return m.name }
func (m *MockProvider) Chat(ctx context.Context, req provider.ChatRequest) (*provider.ChatResponse, error) {
	if m.chatFunc == nil {
		return nil, errors.New("mock: chatFunc not set")
	}
	return m.chatFunc(req)
}
func (m *MockProvider) Models() []provider.ModelInfo { return nil }

func TestRoutingProvider_Disabled(t *testing.T) {
	t.Parallel()
	executorCalled := false
	exec := &MockProvider{
		name: "exec",
		chatFunc: func(req provider.ChatRequest) (*provider.ChatResponse, error) {
			executorCalled = true
			return &provider.ChatResponse{Message: agentctx.StrategicMessage{Content: &agentctx.MessageContent{Str: strPtr("exec response")}}}, nil
		},
	}
	manager := &MockProvider{name: "mgr"}
	cfg := config.RoutingConfig{Enabled: false}
	
	p := provider.NewRoutingProvider(exec, manager, cfg)
	resp, err := p.Chat(context.Background(), provider.ChatRequest{})
	
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !executorCalled {
		t.Error("executor was not called when routing was disabled")
	}
	if resp.Message.Content.String() != "exec response" {
		t.Errorf("got %q, want %q", resp.Message.Content.String(), "exec response")
	}
}

func TestRoutingProvider_BypassConversational(t *testing.T) {
	t.Parallel()
	managerCalled := false
	exec := &MockProvider{name: "exec", chatFunc: func(req provider.ChatRequest) (*provider.ChatResponse, error) {
		return nil, errors.New("executor should not be called")
	}}
	manager := &MockProvider{
		name: "mgr",
		chatFunc: func(req provider.ChatRequest) (*provider.ChatResponse, error) {
			managerCalled = true
			return &provider.ChatResponse{Message: agentctx.StrategicMessage{Content: &agentctx.MessageContent{Str: strPtr("mgr response")}}}, nil
		},
	}
	cfg := config.RoutingConfig{Enabled: true, ManagerModel: "small-model"}
	
	p := provider.NewRoutingProvider(exec, manager, cfg)
	// No tools, short message
	req := provider.ChatRequest{
		Messages: []agentctx.StrategicMessage{{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: strPtr("hello")}}},
	}
	resp, err := p.Chat(context.Background(), req)
	
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !managerCalled {
		t.Error("manager was not called for conversational bypass")
	}
	if resp.Message.Content.String() != "mgr response" {
		t.Errorf("got %q, want %q", resp.Message.Content.String(), "mgr response")
	}
}

func TestRoutingProvider_EscalateToExecutor(t *testing.T) {
	t.Parallel()
	classificationCalled := false
	executorCalled := false
	
	exec := &MockProvider{
		name: "exec",
		chatFunc: func(req provider.ChatRequest) (*provider.ChatResponse, error) {
			executorCalled = true
			return &provider.ChatResponse{Message: agentctx.StrategicMessage{Content: &agentctx.MessageContent{Str: strPtr("exec final response")}}}, nil
		},
	}
	
	manager := &MockProvider{
		name: "mgr",
		chatFunc: func(req provider.ChatRequest) (*provider.ChatResponse, error) {
			// Updated to match single quotes in routing.go
			if strings.Contains(req.SystemInstruction, "'YES' or 'NO'") {
				classificationCalled = true
				return &provider.ChatResponse{Message: agentctx.StrategicMessage{Content: &agentctx.MessageContent{Str: strPtr("YES")}}}, nil
			}
			return nil, fmt.Errorf("unexpected manager call (non-classification), sys: %q", req.SystemInstruction)
		},
	}
	
	cfg := config.RoutingConfig{Enabled: true, ManagerModel: "small-model"}
	p := provider.NewRoutingProvider(exec, manager, cfg)
	
	// Force classification by including tools
	req := provider.ChatRequest{
		Tools: []provider.ToolDeclaration{{Name: "complex_tool"}},
		Messages: []agentctx.StrategicMessage{{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: strPtr("do something complex")}}},
	}
	resp, err := p.Chat(context.Background(), req)
	
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !classificationCalled {
		t.Error("classification was not called")
	}
	if !executorCalled {
		t.Error("executor was not called after YES decision")
	}
	if resp.Message.Content.String() != "exec final response" {
		t.Errorf("got %q, want %q", resp.Message.Content.String(), "exec final response")
	}
}

func TestRoutingProvider_HandleByManager(t *testing.T) {
	t.Parallel()
	classificationCalled := false
	managerFinalCalled := false
	
	exec := &MockProvider{name: "exec", chatFunc: func(req provider.ChatRequest) (*provider.ChatResponse, error) {
		return nil, errors.New("executor should not be called")
	}}
	
	manager := &MockProvider{
		name: "mgr",
		chatFunc: func(req provider.ChatRequest) (*provider.ChatResponse, error) {
			if strings.Contains(req.SystemInstruction, "'YES' or 'NO'") {
				classificationCalled = true
				return &provider.ChatResponse{Message: agentctx.StrategicMessage{Content: &agentctx.MessageContent{Str: strPtr("NO")}}}, nil
			}
			managerFinalCalled = true
			return &provider.ChatResponse{Message: agentctx.StrategicMessage{Content: &agentctx.MessageContent{Str: strPtr("mgr final response")}}}, nil
		},
	}
	
	cfg := config.RoutingConfig{Enabled: true, ManagerModel: "small-model"}
	p := provider.NewRoutingProvider(exec, manager, cfg)
	
	// Long message (> 100 chars) to force classification even without tools
	longMsg := strings.Repeat("this is a very long message that should trigger classification logic even if there are no tools attached to the request ", 2)
	req := provider.ChatRequest{
		Messages: []agentctx.StrategicMessage{{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: strPtr(longMsg)}}},
	}
	resp, err := p.Chat(context.Background(), req)
	
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !classificationCalled {
		t.Error("classification was not called")
	}
	if !managerFinalCalled {
		t.Error("manager final turn was not called after NO decision")
	}
	if resp.Message.Content.String() != "mgr final response" {
		t.Errorf("got %q, want %q", resp.Message.Content.String(), "mgr final response")
	}
}

func TestRoutingProvider_FallbackOnError(t *testing.T) {
	t.Parallel()
	executorCalled := false
	
	exec := &MockProvider{
		name: "exec",
		chatFunc: func(req provider.ChatRequest) (*provider.ChatResponse, error) {
			executorCalled = true
			return &provider.ChatResponse{Message: agentctx.StrategicMessage{Content: &agentctx.MessageContent{Str: strPtr("exec fallback response")}}}, nil
		},
	}
	
	manager := &MockProvider{
		name: "mgr",
		chatFunc: func(req provider.ChatRequest) (*provider.ChatResponse, error) {
			return nil, errors.New("manager api down")
		},
	}
	
	cfg := config.RoutingConfig{Enabled: true, ManagerModel: "small-model"}
	p := provider.NewRoutingProvider(exec, manager, cfg)
	
	// Force classification attempt by using a long message
	longMsg := strings.Repeat("long message ", 20)
	req := provider.ChatRequest{
		Messages: []agentctx.StrategicMessage{{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: strPtr(longMsg)}}},
	}
	resp, err := p.Chat(context.Background(), req)
	
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !executorCalled {
		t.Error("executor was not called as fallback when manager failed")
	}
	if resp.Message.Content.String() != "exec fallback response" {
		t.Errorf("got %q, want %q", resp.Message.Content.String(), "exec fallback response")
	}
}
