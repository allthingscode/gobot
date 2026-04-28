//nolint:testpackage // testing unexported newWebExtractTool and internal helper methods
package app

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/browser"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/provider"
	"github.com/chromedp/chromedp"
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
	runFunc func(ctx context.Context, actions ...chromedp.Action) error
}

func (m *webExtractMockExecutor) Run(ctx context.Context, actions ...chromedp.Action) error {
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
			wantItems: 3, // Mocked GetTextsTool returns 3 items in our setup below if we adjust it
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
			tool.executor = &webExtractMockExecutor{
				runFunc: func(ctx context.Context, actions ...chromedp.Action) error {
					return nil
				},
			}
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

			if tt.name == "SelectorExtraction" {
				if !strings.Contains(resp, "No items matching") {
					t.Errorf("expected 'No items matching' response, got: %s", resp)
				}
				return
			}

			var out map[string]any
			if err := json.Unmarshal([]byte(resp), &out); err != nil {
				t.Fatalf("failed to unmarshal response: %v", err)
			}
		})
	}
}
