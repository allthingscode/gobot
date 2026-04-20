package browser_test

import (
	"context"
	"strings"
	"testing"

	"github.com/chromedp/chromedp"

	"github.com/allthingscode/gobot/internal/browser"
	"github.com/allthingscode/gobot/internal/provider"
)

// mockExecutor implements Executor for testing without a real browser.
type mockExecutor struct {
	err error
}

func (m *mockExecutor) Run(ctx context.Context, actions ...chromedp.Action) error {
	return m.err
}

func getTool(tt toolTest, client *browser.Client) toolInterface {
	switch tt.toolName {
	case "browser_navigate":
		nav := browser.NewNavigateTool(client)
		nav.SetExecutor(&mockExecutor{err: tt.mockErr})
		return nav
	case "browser_screenshot":
		ss := browser.NewScreenshotTool(client)
		ss.SetExecutor(&mockExecutor{err: tt.mockErr})
		return ss
	case "browser_get_text":
		gt := browser.NewGetTextTool(client)
		gt.SetExecutor(&mockExecutor{err: tt.mockErr})
		return gt
	case "browser_click":
		cl := browser.NewClickTool(client)
		cl.SetExecutor(&mockExecutor{err: tt.mockErr})
		return cl
	case "browser_type":
		ty := browser.NewTypeTool(client)
		ty.SetExecutor(&mockExecutor{err: tt.mockErr})
		return ty
	default:
		return nil
	}
}

type toolInterface interface {
	Name() string
	Execute(context.Context, string, string, map[string]any) (string, error)
	Declaration() provider.ToolDeclaration
}

type toolTest struct {
	name       string
	toolName   string
	args       map[string]any
	mockErr    error
	wantErr    bool
	wantResult string
}

func runToolTest(t *testing.T, client *browser.Client, tt toolTest) {
	t.Helper()
	tool := getTool(tt, client)
	if tool == nil {
		t.Fatalf("unknown tool %s", tt.toolName)
	}

	if tool.Name() != tt.toolName {
		t.Errorf("got Name() = %q, want %q", tool.Name(), tt.toolName)
	}

	decl := tool.Declaration()
	if decl.Name == "" {
		t.Errorf("Declaration() returned empty tool name")
	}

	res, err := tool.Execute(context.Background(), "session1", "user1", tt.args)
	if (err != nil) != tt.wantErr {
		t.Errorf("Execute() error = %v, wantErr %v", err, tt.wantErr)
	}
	if !tt.wantErr && !strings.Contains(res, tt.wantResult) {
		t.Errorf("Execute() result = %q, want %q", res, tt.wantResult)
	}
}

func getBrowserTestsPart1() []toolTest {
	return []toolTest{
		{
			name:       "Navigate_Success",
			toolName:   "browser_navigate",
			args:       map[string]any{"url": "https://example.com"},
			wantErr:    false,
			wantResult: "",
		},
		{
			name:     "Navigate_MissingURL",
			toolName: "browser_navigate",
			args:     map[string]any{},
			wantErr:  true,
		},
		{
			name:     "Navigate_ActionError",
			toolName: "browser_navigate",
			args:     map[string]any{"url": "https://example.com"},
			mockErr:  context.Canceled,
			wantErr:  true,
		},
		{
			name:       "Screenshot_Success",
			toolName:   "browser_screenshot",
			args:       map[string]any{},
			wantErr:    false,
			wantResult: "",
		},
		{
			name:     "Screenshot_ActionError",
			toolName: "browser_screenshot",
			args:     map[string]any{},
			mockErr:  context.Canceled,
			wantErr:  true,
		},
		{
			name:       "GetText_Success",
			toolName:   "browser_get_text",
			args:       map[string]any{"selector": "h1"},
			wantErr:    false,
			wantResult: "",
		},
		{
			name:     "GetText_MissingSelector",
			toolName: "browser_get_text",
			args:     map[string]any{"selector": " "},
			wantErr:  true,
		},
		{
			name:     "GetText_ActionError",
			toolName: "browser_get_text",
			args:     map[string]any{"selector": "h1"},
			mockErr:  context.Canceled,
			wantErr:  true,
		},
	}
}

func getBrowserTestsPart2() []toolTest {
	return []toolTest{
		{
			name:       "Click_Success",
			toolName:   "browser_click",
			args:       map[string]any{"selector": "button"},
			wantErr:    false,
			wantResult: "clicked",
		},
		{
			name:     "Click_MissingSelector",
			toolName: "browser_click",
			args:     map[string]any{},
			wantErr:  true,
		},
		{
			name:     "Click_ActionError",
			toolName: "browser_click",
			args:     map[string]any{"selector": "button"},
			mockErr:  context.Canceled,
			wantErr:  true,
		},
		{
			name:       "Type_Success",
			toolName:   "browser_type",
			args:       map[string]any{"selector": "input", "text": "hello"},
			wantErr:    false,
			wantResult: "typed",
		},
		{
			name:     "Type_MissingSelector",
			toolName: "browser_type",
			args:     map[string]any{"selector": "", "text": "hello"},
			wantErr:  true,
		},
		{
			name:     "Type_MissingText",
			toolName: "browser_type",
			args:     map[string]any{"selector": "input", "text": ""},
			wantErr:  true,
		},
		{
			name:     "Type_ActionError",
			toolName: "browser_type",
			args:     map[string]any{"selector": "input", "text": "hello"},
			mockErr:  context.Canceled,
			wantErr:  true,
		},
	}
}

func TestBrowserTools(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	client := browser.NewClientForTest(ctx, cancel)

	tests := append(getBrowserTestsPart1(), getBrowserTestsPart2()...)

	for _, tt := range tests {
		tt := tt // capture loop variable
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			runToolTest(t, client, tt)
		})
	}
}

func TestDefaultExecutor(t *testing.T) {
	t.Parallel()
	var e browser.Executor = browser.DefaultExecutor{}
	_ = e
}
