//nolint:testpackage // testing unexported newWebExtractTool and internal helper methods
package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/browser"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/provider"
)

type webExtractMockProvider struct {
	responses []string
	idx       int
}

func (m *webExtractMockProvider) Name() string { return "mock" }
func (m *webExtractMockProvider) Chat(ctx context.Context, req provider.ChatRequest) (*provider.ChatResponse, error) {
	if m.idx >= len(m.responses) {
		return nil, fmt.Errorf("no more mock responses")
	}
	resp := m.responses[m.idx]
	m.idx++
	return &provider.ChatResponse{
		Message: agentctx.StrategicMessage{
			Role:    agentctx.RoleAssistant,
			Content: &agentctx.MessageContent{Str: &resp},
		},
	}, nil
}
func (m *webExtractMockProvider) Models() []provider.ModelInfo { return nil }

type webExtractMockExecutor struct {
	runFunc func(ctx context.Context, actions ...browser.Action) error
}

func TestCapturePageMapResults(t *testing.T) {
	t.Parallel()
	for _, fail := range []bool{false, true} {
		name := "mapping returned"
		if fail {
			name = "failure"
		}
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			checkPageMapResult(t, fail)
		})
	}
}

func checkPageMapResult(t *testing.T, fail bool) {
	t.Helper()
	want := `{"title":"Example","snippet":"Content"}`
	sentinel := errors.New("evaluate failed")
	tool := newWebExtractTool(&config.Config{}, nil, "")
	var runErr error
	if fail {
		runErr = sentinel
	}
	tool.executor = pageMapExecutor(t, want, runErr)
	got, err := tool.capturePageMap(context.Background())
	if fail {
		if !errors.Is(err, sentinel) || !strings.Contains(err.Error(), "web_extract: page mapping") {
			t.Fatalf("error = %v; want wrapped mapping error", err)
		}
		return
	}
	if err != nil || got != want {
		t.Fatalf("mapping = %q, %v; want %q", got, err, want)
	}
}

func pageMapExecutor(t *testing.T, want string, runErr error) *webExtractMockExecutor {
	t.Helper()
	return &webExtractMockExecutor{runFunc: func(ctx context.Context, actions ...browser.Action) error {
		if runErr != nil {
			return runErr
		}
		if len(actions) != 1 {
			t.Fatalf("mapping has %d actions", len(actions))
		}
		step, ok := actions[0].(browser.ResultAction[string])
		if !ok {
			t.Fatalf("mapping action type = %T", actions[0])
		}
		*step.Result = want
		return nil
	}}
}

func webExtractResults(ctx context.Context, actions ...browser.Action) error {
	for _, action := range actions {
		switch step := action.(type) {
		case browser.ResultAction[string]:
			*step.Result = `{"snippet":"Page content"}`
			if len(actions) == 2 {
				*step.Result = "Example page"
			}
		case browser.ResultAction[[]string]:
			*step.Result = []string{"First", "Second", "Third"}
		}
	}
	return nil
}

func (m *webExtractMockExecutor) Run(ctx context.Context, actions ...browser.Action) error {
	if m.runFunc != nil {
		return m.runFunc(ctx, actions...)
	}
	return nil
}

func TestWebExtractTool_Execute(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name      string
		responses []string
		wantItems int
	}{
		{
			name: "DirectData",
			responses: []string{
				`{"data": ["Item 1", "Item 2"], "summary": "Extracted directly."}`,
				"Summary.",
			},
			wantItems: 2,
		},
		{
			name: "SelectorExtraction",
			responses: []string{
				`{"selector": ".title", "reasoning": "Standard titles."}`,
				"Summary.",
			},
			wantItems: 3,
		},
		{
			name: "JSONFallback",
			responses: []string{
				`Sure, here is the plan: {"data": ["Fallback Item"], "summary": "Found it."} hope this helps!`,
				"Summary.",
			},
			wantItems: 1,
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			cfg := &config.Config{
				Browser: config.BrowserConfig{
					Headless: true,
				},
			}

			prov := &webExtractMockProvider{
				responses: tt.responses,
			}

			tool := newWebExtractTool(cfg, prov, "test-model")
			tool.executor = &webExtractMockExecutor{runFunc: webExtractResults}
			tool.clientFactory = func(cfg config.BrowserConfig) (*browser.Client, error) {
				return browser.NewClientForTest(context.Background(), func() {}), nil
			}

			args := map[string]any{
				"url":  "http://example.com",
				"goal": "extract titles",
			}

			resp, err := tool.Execute(context.Background(), "session", "user", args)
			if err != nil {
				t.Fatalf("Execute failed: %v", err)
			}

			var out map[string]any
			if err := json.Unmarshal([]byte(resp), &out); err != nil {
				t.Fatalf("failed to unmarshal response: %v", err)
			}
			items, ok := out["items"].([]any)
			if !ok || len(items) != tt.wantItems || out["page_title"] != "Example page" {
				t.Fatalf("response lost results: %s; want %d items and page title", resp, tt.wantItems)
			}
		})
	}
}

func TestClassifyPageConstraint(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name        string
		title       string
		pageMapJSON string
		waitResult  browser.DynamicWaitResult
		wantClass   string
		wantSignal  string
	}{
		{
			name:        "AuthRequired",
			title:       "Sign In",
			pageMapJSON: `{"snippet":"Please log in to continue"}`,
			waitResult:  browser.DynamicWaitResult{Completed: true},
			wantClass:   "auth_required",
			wantSignal:  "auth_signal",
		},
		{
			name:        "AntiBotBlocked",
			title:       "Attention Required",
			pageMapJSON: `{"snippet":"Verify you are human"}`,
			waitResult:  browser.DynamicWaitResult{Completed: true},
			wantClass:   "anti_bot_blocked",
			wantSignal:  "anti_bot_signal",
		},
		{
			name:        "DynamicPending",
			title:       "News",
			pageMapJSON: `{"snippet":"Latest updates"}`,
			waitResult:  browser.DynamicWaitResult{Completed: false, TimedOut: true},
			wantClass:   "dynamic_pending",
			wantSignal:  "dynamic_wait_timeout",
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			gotClass, gotSignal := classifyPageConstraint(tt.title, tt.pageMapJSON, tt.waitResult)
			if gotClass != tt.wantClass {
				t.Fatalf("classification = %q, want %q", gotClass, tt.wantClass)
			}
			if gotSignal != tt.wantSignal {
				t.Fatalf("signal = %q, want %q", gotSignal, tt.wantSignal)
			}
		})
	}
}
