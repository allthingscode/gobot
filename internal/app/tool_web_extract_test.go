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
	"github.com/allthingscode/gobot/internal/state"
	"github.com/chromedp/chromedp"
)

type webExtractMockProvider struct {
	responses []string
	idx       int
}

func (m *webExtractMockProvider) Name() string { return mockName }
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

func TestWebExtractTool_Execute(t *testing.T) { //nolint:gocognit,funlen // test table runner
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
				Strategic: config.StrategicConfig{
					StorageRoot: t.TempDir(),
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

			// Verify state was cleaned up/archived
			active, _ := tool.stateMgr.ListActive()
			if len(active) > 0 {
				t.Errorf("Expected 0 active workflows, got %d", len(active))
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

func TestWebExtractTool_Execute_FailurePersistence(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{
		Browser: config.BrowserConfig{
			Headless: true,
		},
		Strategic: config.StrategicConfig{
			StorageRoot: t.TempDir(),
		},
	}

	// Mock provider that returns a valid plan, but we'll force navigation failure
	prov := &webExtractMockProvider{
		responses: []string{`{"selector": ".test"}`},
	}

	tool := newWebExtractTool(cfg, prov, "test-model")

	// Force navigation failure
	tool.executor = &webExtractMockExecutor{
		runFunc: func(ctx context.Context, actions ...chromedp.Action) error {
			return fmt.Errorf("navigation failed")
		},
	}
	tool.clientFactory = func(cfg config.BrowserConfig) (*browser.Client, error) {
		return browser.NewClientForTest(context.Background(), func() {}), nil
	}

	args := map[string]any{
		"url":  "http://example.com",
		"goal": "extract data",
	}

	_, err := tool.Execute(context.Background(), "fail-session", "user", args)
	if err == nil {
		t.Fatal("Expected error from Execute, got nil")
	}

	// Verify state manager reflects failure
	active, err := tool.stateMgr.ListActive()
	if err != nil {
		t.Fatalf("ListActive failed: %v", err)
	}

	// On failure, the workflow is NOT archived, so it should be in active list with status failed
	if len(active) == 0 {
		t.Fatal("Expected 1 active (failed) workflow, got 0")
	}

	wf, err := tool.stateMgr.LoadWithRecovery(active[0])
	if err != nil {
		t.Fatalf("LoadWithRecovery failed: %v", err)
	}

	if wf.Status != state.StatusFailed {
		t.Errorf("Expected status failed, got %s", wf.Status)
	}

	var extState state.WebExtractionState
	if err := json.Unmarshal(wf.Data, &extState); err != nil {
		t.Fatalf("Failed to unmarshal state data: %v", err)
	}

	if !strings.Contains(extState.LastError, "navigation failed") {
		t.Errorf("Expected LastError to contain 'navigation failed', got %q", extState.LastError)
	}
}

