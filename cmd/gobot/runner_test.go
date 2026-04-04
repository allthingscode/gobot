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
		{Role: "user", Content: &agentctx.MessageContent{Str: &s1}},
		{Role: "assistant", Content: &agentctx.MessageContent{Str: &s2}},
	}

	got := lastUserText(messages)
	if got != "msg 1" {
		t.Errorf("lastUserText() = %q, want %q", got, "msg 1")
	}

	s3 := "msg 3"
	messages = append(messages, agentctx.StrategicMessage{Role: "user", Content: &agentctx.MessageContent{Str: &s3}})
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
				Role:    "assistant",
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
		{Role: "user", Content: &agentctx.MessageContent{Str: &userMsg}},
	}

	got, _, err := r.Run(context.Background(), "test-session", messages)
	if err != nil {
		t.Fatalf("Run() error: %v", err)
	}
	if got != "corrected attempt" {
		t.Errorf("Run() = %q, want %q (reflection should have triggered backtrack)", got, "corrected attempt")
	}
}
