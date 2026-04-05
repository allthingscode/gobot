package main

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"golang.org/x/time/rate"

	"github.com/allthingscode/gobot/internal/agent"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/provider"
	"github.com/allthingscode/gobot/internal/resilience"
)

func TestExtractText(t *testing.T) {
	s1 := "hello"
	tests := []struct {
		name string
		msg  agentctx.StrategicMessage
		want string
	}{
		{
			name: "single text string",
			msg: agentctx.StrategicMessage{
				Content: &agentctx.MessageContent{Str: &s1},
			},
			want: "hello",
		},
		{
			name: "multiple text items",
			msg: agentctx.StrategicMessage{
				Content: &agentctx.MessageContent{
					Items: []agentctx.ContentItem{
						{Text: &agentctx.TextContent{Text: "hello"}},
						{Text: &agentctx.TextContent{Text: " "}},
						{Text: &agentctx.TextContent{Text: "world"}},
					},
				},
			},
			want: "hello world",
		},
		{
			name: "empty message",
			msg:  agentctx.StrategicMessage{},
			want: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := extractText(tt.msg)
			if got != tt.want {
				t.Errorf("extractText() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestTruncateToolResult(t *testing.T) {
	tests := []struct {
		name     string
		result   string
		maxBytes int
		want     string
	}{
		{
			name:     "empty string",
			result:   "",
			maxBytes: 10,
			want:     "",
		},
		{
			name:     "under limit",
			result:   "hello",
			maxBytes: 10,
			want:     "hello",
		},
		{
			name:     "exactly at limit",
			result:   "1234567890",
			maxBytes: 10,
			want:     "1234567890",
		},
		{
			name:     "over limit",
			result:   "1234567890-excess",
			maxBytes: 10,
			want:     "1234567890\n\n[... truncated: result exceeded 10 bytes ...]",
		},
		{
			name:     "disabled (zero)",
			result:   "long string",
			maxBytes: 0,
			want:     "long string",
		},
		{
			name:     "disabled (negative)",
			result:   "long string",
			maxBytes: -1,
			want:     "long string",
		},
		{
			name:     "utf-8 multi-byte boundary (keep)",
			result:   "Hello 世界", // "世界" is 6 bytes. Total 12 bytes.
			maxBytes: 9,        // Should keep "Hello 世" (9 bytes)
			want:     "Hello 世\n\n[... truncated: result exceeded 9 bytes ...]",
		},
		{
			name:     "utf-8 multi-byte boundary (cut middle)",
			result:   "Hello 世界",
			maxBytes: 8,        // Cuts in middle of "世". Should fallback to "Hello " (6 bytes).
			want:     "Hello \n\n[... truncated: result exceeded 8 bytes ...]",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := truncateToolResult(tt.result, tt.maxBytes)
			if got != tt.want {
				t.Errorf("truncateToolResult() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestRunner_SetHooks(t *testing.T) {
	r := &geminiRunner{}
	h := &agent.Hooks{}
	r.SetHooks(h)
	if r.hooks != h {
		t.Errorf("SetHooks failed: r.hooks = %v, want %v", r.hooks, h)
	}
}

func TestLastUserText(t *testing.T) {
	s1 := "msg 1"
	s2 := "msg 2"
	messages := []agentctx.StrategicMessage{
		{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: &s1}},
		{Role: agentctx.RoleAssistant, Content: &agentctx.MessageContent{Str: &s2}},
	}

	got := lastUserText(messages)
	if got != "msg 1" {
		t.Errorf("lastUserText() = %q, want %q", got, "msg 1")
	}

	s3 := "msg 3"
	messages = append(messages, agentctx.StrategicMessage{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: &s3}})
	got = lastUserText(messages)
	if got != "msg 3" {
		t.Errorf("lastUserText() = %q, want %q", got, "msg 3")
	}
}

func TestBuildCorrectionMessage(t *testing.T) {
	tests := []struct {
		name   string
		report map[string]any
		checks []string
	}{
		{
			name: "feedback only",
			report: map[string]any{
				"feedback":             "Missing details",
				"required_corrections": []any{},
			},
			checks: []string{"Missing details", "revise"},
		},
		{
			name: "single correction",
			report: map[string]any{
				"feedback":             "Incomplete",
				"required_corrections": []any{"Add step 3"},
			},
			checks: []string{"Add step 3", "1."},
		},
		{
			name: "multiple corrections",
			report: map[string]any{
				"feedback":             "Several issues",
				"required_corrections": []any{"Fix A", "Fix B"},
			},
			checks: []string{"Fix A", "Fix B", "1.", "2."},
		},
		{
			name:   "empty report",
			report: map[string]any{},
			checks: []string{"revise"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := buildCorrectionMessage(tt.report)
			for _, check := range tt.checks {
				if !strings.Contains(got, check) {
					t.Errorf("buildCorrectionMessage() missing %q in output:\n%s", check, got)
				}
			}
		})
	}
}

func TestRunner_ReflectionDefaults(t *testing.T) {
	r := &geminiRunner{
		maxReflectionRounds: 1,
		enableReflection:    false,
	}
	if r.enableReflection {
		t.Error("enableReflection should default to false")
	}
	if r.maxReflectionRounds != 1 {
		t.Errorf("maxReflectionRounds = %d, want 1", r.maxReflectionRounds)
	}
}

type mockProvider struct {
	responses []*provider.ChatResponse
	idx       int
}

func (m *mockProvider) Name() string                 { return "mock" }
func (m *mockProvider) Models() []provider.ModelInfo { return nil }
func (m *mockProvider) Chat(_ context.Context, _ provider.ChatRequest) (*provider.ChatResponse, error) {
	if m.idx >= len(m.responses) {
		return nil, fmt.Errorf("mockProvider: no more responses (call %d)", m.idx)
	}
	resp := m.responses[m.idx]
	m.idx++
	return resp, nil
}

func strPtr(s string) *string { return &s }

func TestRunner_ReflectionLoop(t *testing.T) {
	rubricJSON := `{"task_goal":"test","criteria":[{"name":"Quality","description":"good","weight":1.0}],"success_threshold":0.9}`
	criticFail := `{"overall_score":0.3,"scores":[{"criterion_name":"Quality","score":0.3,"reasoning":"poor"}],"passed":false,"feedback":"needs work","required_corrections":["improve X"]}`
	criticPass := `{"overall_score":0.95,"scores":[{"criterion_name":"Quality","score":0.95,"reasoning":"excellent"}],"passed":true,"feedback":"great","required_corrections":[]}`

	makeTextResp := func(text string) *provider.ChatResponse {
		return &provider.ChatResponse{
			Message: agentctx.StrategicMessage{
				Role:    agentctx.RoleAssistant,
				Content: &agentctx.MessageContent{Str: strPtr(text)},
			},
		}
	}

	mock := &mockProvider{
		responses: []*provider.ChatResponse{
			makeTextResp(rubricJSON),          // call 0: planning rubric
			makeTextResp("first attempt"),     // call 1: main loop terminal
			makeTextResp(criticFail),          // call 2: critic fails
			makeTextResp("corrected attempt"), // call 3: backtrack terminal
			makeTextResp(criticPass),          // call 4: critic passes
		},
	}

	r := &geminiRunner{
		prov:                mock,
		model:               "mock-model",
		maxToolIterations:   10,
		enableReflection:    true,
		maxReflectionRounds: 1,
		limiter:             rate.NewLimiter(rate.Inf, 1),
		breaker:             resilience.New("mock", 5, time.Minute, time.Second),
	}

	userMsg := "test task"
	messages := []agentctx.StrategicMessage{
		{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: &userMsg}},
	}

	got, _, err := r.Run(context.Background(), "test-session", messages)
	if err != nil {
		t.Fatalf("Run() error: %v", err)
	}
	if got != "corrected attempt" {
		t.Errorf("Run() = %q, want %q (reflection should have triggered backtrack)", got, "corrected attempt")
	}
}

func TestRunner_ToolCallValidation(t *testing.T) {
	tests := []struct {
		name      string
		toolCalls []map[string]any
		wantErr   string
	}{
		{
			name: "valid call",
			toolCalls: []map[string]any{
				{"name": "test_tool", "args": map[string]any{"arg1": "val1"}},
			},
			wantErr: "",
		},
		{
			name: "missing name",
			toolCalls: []map[string]any{
				{"args": map[string]any{}},
			},
			wantErr: "missing or non-string 'name' field",
		},
		{
			name: "wrong name type",
			toolCalls: []map[string]any{
				{"name": 123, "args": map[string]any{}},
			},
			wantErr: "missing or non-string 'name' field",
		},
		{
			name: "missing args",
			toolCalls: []map[string]any{
				{"name": "test_tool"},
			},
			wantErr: "missing or non-map 'args' field",
		},
		{
			name: "wrong args type",
			toolCalls: []map[string]any{
				{"name": "test_tool", "args": "invalid"},
			},
			wantErr: "missing or non-map 'args' field",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mock := &mockProvider{
				responses: []*provider.ChatResponse{
					{
						Message: agentctx.StrategicMessage{
							Role:      agentctx.RoleAssistant,
							ToolCalls: tt.toolCalls,
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

			r := &geminiRunner{
				prov:              mock,
				model:             "mock-model",
				maxToolIterations: 10,
				limiter:           rate.NewLimiter(rate.Inf, 1),
				breaker:           resilience.New("mock", 5, time.Minute, time.Second),
				tools: []Tool{
					&mockTool{name: "test_tool"},
				},
			}

			got, _, err := r.Run(context.Background(), "test-session", nil)
			if tt.wantErr != "" {
				if err == nil {
					t.Fatal("Run() expected error, got nil")
				}
				if !strings.Contains(err.Error(), tt.wantErr) {
					t.Errorf("Run() error = %q, want error containing %q", err, tt.wantErr)
				}
			} else {
				if err != nil {
					t.Fatalf("Run() error = %v, want nil", err)
				}
				if got != "done" {
					t.Errorf("Run() got %q, want %q", got, "done")
				}
			}
		})
	}
}

type mockTool struct {
	name string
}

func (m *mockTool) Name() string                     { return m.name }
func (m *mockTool) Description() string              { return "mock" }
func (m *mockTool) Declaration() provider.ToolDeclaration { return provider.ToolDeclaration{Name: m.name} }
func (m *mockTool) Execute(_ context.Context, _ string, _ map[string]any) (string, error) {
	return "result", nil
}
type panicTool struct {}
func (p *panicTool) Name() string                     { return "panic_tool" }
func (p *panicTool) Description() string              { return "panics" }
func (p *panicTool) Declaration() provider.ToolDeclaration { return provider.ToolDeclaration{Name: "panic_tool"} }
func (p *panicTool) Execute(_ context.Context, _ string, _ map[string]any) (string, error) {
	panic("simulated panic")
}

func TestRunner_ToolPanicRecovery(t *testing.T) {
	r := &geminiRunner{
		tools: []Tool{&panicTool{}},
	}
	ctx := context.Background()
	result, err := r.executeToolInner(ctx, "session-123", "panic_tool", nil)
	
	if err == nil {
		t.Fatal("Expected error due to panic, got nil")
	}
	expectedMsg := "tool panic_tool panicked: simulated panic"
	if err.Error() != expectedMsg {
		t.Errorf("Expected error %q, got %q", expectedMsg, err.Error())
	}
	if result != "" {
		t.Errorf("Expected empty result, got %q", result)
	}
}


type largeTool struct {
	size int
}

func (l *largeTool) Name() string                     { return "large_tool" }
func (l *largeTool) Description() string              { return "returns large string" }
func (l *largeTool) Declaration() provider.ToolDeclaration { return provider.ToolDeclaration{Name: "large_tool"} }
func (l *largeTool) Execute(_ context.Context, _ string, _ map[string]any) (string, error) {
	return strings.Repeat("A", l.size), nil
}

func TestRunner_ToolResultSizeLimiting(t *testing.T) {
	mock := &mockProvider{
		responses: []*provider.ChatResponse{
			{
				Message: agentctx.StrategicMessage{
					Role: agentctx.RoleAssistant,
					ToolCalls: []map[string]any{
						{"name": "large_tool", "args": map[string]any{}},
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

	r := &geminiRunner{
		prov:               mock,
		model:              "mock-model",
		maxToolIterations:  10,
		maxToolResultBytes: 100,
		limiter:            rate.NewLimiter(rate.Inf, 1),
		breaker:            resilience.New("mock", 5, time.Minute, time.Second),
		tools: []Tool{
			&largeTool{size: 200},
		},
	}

	_, messages, err := r.Run(context.Background(), "test-session", nil)
	if err != nil {
		t.Fatalf("Run() error: %v", err)
	}

	// Find the tool message
	var toolMsg *agentctx.StrategicMessage
	for _, m := range messages {
		if m.Role == agentctx.RoleTool {
			toolMsg = &m
			break
		}
	}

	if toolMsg == nil {
		t.Fatal("Tool message not found in history")
	}

	content := *toolMsg.Content.Str
	if len(content) > 200 { // Should be 100 + notice
		t.Errorf("Tool result not truncated, length: %d", len(content))
	}
	if !strings.Contains(content, "truncated") {
		t.Errorf("Tool result missing truncation notice: %q", content)
	}
	if len(content) != 100 + len(fmt.Sprintf("\n\n[... truncated: result exceeded %d bytes ...]", 100)) {
		t.Errorf("Unexpected truncated length: %d", len(content))
	}
}
