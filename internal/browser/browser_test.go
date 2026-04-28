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
	builders := map[string]func(*browser.Client, error) toolInterface{
		"browser_navigate":   buildNavigateTool,
		"browser_screenshot": buildScreenshotTool,
		"browser_get_text":   buildGetTextTool,
		"browser_wait_for":   buildWaitForTool,
		"browser_extract":    buildExtractTool,
		"browser_get_texts":  buildGetTextsTool,
		"browser_click":      buildClickTool,
		"browser_type":       buildTypeTool,
	}
	builder, ok := builders[tt.toolName]
	if !ok {
		return nil
	}
	return builder(client, tt.mockErr)
}

func buildNavigateTool(client *browser.Client, err error) toolInterface {
	nav := browser.NewNavigateTool(client)
	nav.SetExecutor(&mockExecutor{err: err})
	return nav
}

func buildScreenshotTool(client *browser.Client, err error) toolInterface {
	ss := browser.NewScreenshotTool(client)
	ss.SetExecutor(&mockExecutor{err: err})
	return ss
}

func buildGetTextTool(client *browser.Client, err error) toolInterface {
	gt := browser.NewGetTextTool(client)
	gt.SetExecutor(&mockExecutor{err: err})
	return gt
}

func buildWaitForTool(client *browser.Client, err error) toolInterface {
	wf := browser.NewWaitForTool(client)
	wf.SetExecutor(&mockExecutor{err: err})
	return wf
}

func buildExtractTool(client *browser.Client, err error) toolInterface {
	ex := browser.NewExtractTool(client)
	ex.SetExecutor(&mockExecutor{err: err})
	ex.SetExtractFunc(func(ctx context.Context, limit int, selector string) ([]string, error) {
		if err != nil {
			return nil, err
		}
		return []string{"sample text"}, nil
	})
	return ex
}

func buildGetTextsTool(client *browser.Client, err error) toolInterface {
	gts := browser.NewGetTextsTool(client)
	gts.SetExecutor(&mockExecutor{err: err})
	return gts
}

func buildClickTool(client *browser.Client, err error) toolInterface {
	cl := browser.NewClickTool(client)
	cl.SetExecutor(&mockExecutor{err: err})
	return cl
}

func buildTypeTool(client *browser.Client, err error) toolInterface {
	ty := browser.NewTypeTool(client)
	ty.SetExecutor(&mockExecutor{err: err})
	return ty
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
	return append(append(getBrowserCoreNavigationTests(), getBrowserCoreExtractionTests()...), getBrowserExtractTests()...)
}

func getBrowserCoreNavigationTests() []toolTest {
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
			name:       "WaitFor_Success",
			toolName:   "browser_wait_for",
			args:       map[string]any{"selector": "h1", "timeout_millis": 1000},
			wantErr:    false,
			wantResult: "ready",
		},
		{
			name:     "WaitFor_MissingSelector",
			toolName: "browser_wait_for",
			args:     map[string]any{"selector": " "},
			wantErr:  true,
		},
		{
			name:     "WaitFor_ActionError",
			toolName: "browser_wait_for",
			args:     map[string]any{"selector": "h1"},
			mockErr:  context.Canceled,
			wantErr:  true,
		},
	}
}

func getBrowserCoreExtractionTests() []toolTest {
	return []toolTest{
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
		{
			name:       "GetTexts_Success",
			toolName:   "browser_get_texts",
			args:       map[string]any{"selector": ".titleline > a", "limit": 5},
			wantErr:    false,
			wantResult: "[",
		},
		{
			name:     "GetTexts_MissingSelector",
			toolName: "browser_get_texts",
			args:     map[string]any{"selector": " "},
			wantErr:  true,
		},
		{
			name:     "GetTexts_ActionError",
			toolName: "browser_get_texts",
			args:     map[string]any{"selector": ".titleline > a"},
			mockErr:  context.Canceled,
			wantErr:  true,
		},
	}
}

func getBrowserExtractTests() []toolTest {
	return []toolTest{
		{
			name:       "Extract_Success",
			toolName:   "browser_extract",
			args:       map[string]any{"url": "https://news.ycombinator.com", "wait_selector": ".titleline > a", "extract_selector": ".titleline > a", "limit": 5},
			wantErr:    false,
			wantResult: "\"items\"",
		},
		{
			name:     "Extract_MissingURL",
			toolName: "browser_extract",
			args:     map[string]any{"wait_selector": ".titleline > a", "extract_selector": ".titleline > a"},
			wantErr:  true,
		},
		{
			name:     "Extract_MissingWaitSelector",
			toolName: "browser_extract",
			args:     map[string]any{"url": "https://news.ycombinator.com", "extract_selector": ".titleline > a"},
			wantErr:  true,
		},
		{
			name:     "Extract_MissingExtractSelector",
			toolName: "browser_extract",
			args:     map[string]any{"url": "https://news.ycombinator.com", "wait_selector": ".titleline > a"},
			wantErr:  false,
		},
		{
			name:     "Extract_ActionError",
			toolName: "browser_extract",
			args:     map[string]any{"url": "https://news.ycombinator.com", "wait_selector": ".titleline > a", "extract_selector": ".titleline > a"},
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
