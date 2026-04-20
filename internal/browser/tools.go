package browser

import (
	"context"
	"encoding/base64"
	"fmt"
	"strings"

	"github.com/chromedp/chromedp"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/provider"
)

// Executor is an interface for chromedp.Run to allow mocking in tests.
type Executor interface {
	Run(ctx context.Context, actions ...chromedp.Action) error
}

// DefaultExecutor wraps chromedp.Run.
type DefaultExecutor struct{}

func (e DefaultExecutor) Run(ctx context.Context, actions ...chromedp.Action) error {
	if err := chromedp.Run(ctx, actions...); err != nil {
		return fmt.Errorf("chromedp run failed: %w", err)
	}
	return nil
}

type NavigateTool struct {
	client   *Client
	executor Executor
}

// NewNavigateTool creates a new instance of the NavigateTool.
func NewNavigateTool(c *Client) *NavigateTool {
	return &NavigateTool{client: c, executor: DefaultExecutor{}}
}

// SetExecutor is used for testing.
func (t *NavigateTool) SetExecutor(e Executor) { t.executor = e }

func (t *NavigateTool) Name() string { return "browser_navigate" }

type navigateArgs struct {
	URL string `json:"url" schema:"The URL to navigate to."`
}

func (t *NavigateTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        t.Name(),
		Description: "Navigate to a URL and return the page title.",
		Parameters:  agent.DeriveSchema(navigateArgs{}),
	}
}

func (t *NavigateTool) Execute(ctx context.Context, sessionKey, userID string, args map[string]any) (string, error) {
	urlStr, _ := args["url"].(string)
	if urlStr == "" {
		return "", fmt.Errorf("url is required")
	}

	tabCtx, cancel := chromedp.NewContext(t.client.ctx)
	defer cancel()

	var title string
	err := t.executor.Run(tabCtx,
		chromedp.Navigate(urlStr),
		chromedp.Title(&title),
	)
	if err != nil {
		return "", fmt.Errorf("failed to navigate: %w", err)
	}

	return title, nil
}

type ScreenshotTool struct {
	client   *Client
	executor Executor
}

// NewScreenshotTool creates a new instance of the ScreenshotTool.
func NewScreenshotTool(c *Client) *ScreenshotTool {
	return &ScreenshotTool{client: c, executor: DefaultExecutor{}}
}

// SetExecutor is used for testing.
func (t *ScreenshotTool) SetExecutor(e Executor) { t.executor = e }

func (t *ScreenshotTool) Name() string { return "browser_screenshot" }

type screenshotArgs struct{}

func (t *ScreenshotTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        t.Name(),
		Description: "Capture a full-page PNG screenshot of the current page. Returns a base64-encoded string.",
		Parameters:  agent.DeriveSchema(screenshotArgs{}),
	}
}

func (t *ScreenshotTool) Execute(ctx context.Context, sessionKey, userID string, args map[string]any) (string, error) {
	tabCtx, cancel := chromedp.NewContext(t.client.ctx)
	defer cancel()

	var buf []byte
	err := t.executor.Run(tabCtx, chromedp.FullScreenshot(&buf, 90))
	if err != nil {
		return "", fmt.Errorf("failed to capture screenshot: %w", err)
	}

	return base64.StdEncoding.EncodeToString(buf), nil
}

type GetTextTool struct {
	client   *Client
	executor Executor
}

// NewGetTextTool creates a new instance of the GetTextTool.
func NewGetTextTool(c *Client) *GetTextTool {
	return &GetTextTool{client: c, executor: DefaultExecutor{}}
}

// SetExecutor is used for testing.
func (t *GetTextTool) SetExecutor(e Executor) { t.executor = e }

func (t *GetTextTool) Name() string { return "browser_get_text" }

type getTextArgs struct {
	Selector string `json:"selector" schema:"The CSS selector of the element to read."`
}

func (t *GetTextTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        t.Name(),
		Description: "Return the innerText of the first element matching the CSS selector.",
		Parameters:  agent.DeriveSchema(getTextArgs{}),
	}
}

func (t *GetTextTool) Execute(ctx context.Context, sessionKey, userID string, args map[string]any) (string, error) {
	selector, _ := args["selector"].(string)
	if strings.TrimSpace(selector) == "" {
		return "", fmt.Errorf("selector is required")
	}

	tabCtx, cancel := chromedp.NewContext(t.client.ctx)
	defer cancel()

	var text string
	err := t.executor.Run(tabCtx, chromedp.Text(selector, &text, chromedp.ByQuery))
	if err != nil {
		return "", fmt.Errorf("failed to get text for selector %q: %w", selector, err)
	}

	return text, nil
}

type ClickTool struct {
	client   *Client
	executor Executor
}

// NewClickTool creates a new instance of the ClickTool.
func NewClickTool(c *Client) *ClickTool {
	return &ClickTool{client: c, executor: DefaultExecutor{}}
}

// SetExecutor is used for testing.
func (t *ClickTool) SetExecutor(e Executor) { t.executor = e }

func (t *ClickTool) Name() string { return "browser_click" }

type clickArgs struct {
	Selector string `json:"selector" schema:"The CSS selector of the element to click."`
}

func (t *ClickTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        t.Name(),
		Description: "Click the element matching the CSS selector.",
		Parameters:  agent.DeriveSchema(clickArgs{}),
	}
}

func (t *ClickTool) Execute(ctx context.Context, sessionKey, userID string, args map[string]any) (string, error) {
	selector, _ := args["selector"].(string)
	if strings.TrimSpace(selector) == "" {
		return "", fmt.Errorf("selector is required")
	}

	tabCtx, cancel := chromedp.NewContext(t.client.ctx)
	defer cancel()

	err := t.executor.Run(tabCtx, chromedp.Click(selector, chromedp.ByQuery))
	if err != nil {
		return "", fmt.Errorf("failed to click selector %q: %w", selector, err)
	}

	return "clicked", nil
}

type TypeTool struct {
	client   *Client
	executor Executor
}

// NewTypeTool creates a new instance of the TypeTool.
func NewTypeTool(c *Client) *TypeTool {
	return &TypeTool{client: c, executor: DefaultExecutor{}}
}

// SetExecutor is used for testing.
func (t *TypeTool) SetExecutor(e Executor) { t.executor = e }

func (t *TypeTool) Name() string { return "browser_type" }

type typeArgs struct {
	Selector string `json:"selector" schema:"The CSS selector of the element."`
	Text     string `json:"text" schema:"The text to type into the element."`
}

func (t *TypeTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        t.Name(),
		Description: "Focus the element matching the CSS selector and type text into it.",
		Parameters:  agent.DeriveSchema(typeArgs{}),
	}
}

func (t *TypeTool) Execute(ctx context.Context, sessionKey, userID string, args map[string]any) (string, error) {
	selector, _ := args["selector"].(string)
	if strings.TrimSpace(selector) == "" {
		return "", fmt.Errorf("selector is required")
	}

	textStr, _ := args["text"].(string)
	if textStr == "" {
		return "", fmt.Errorf("text is required")
	}

	tabCtx, cancel := chromedp.NewContext(t.client.ctx)
	defer cancel()

	err := t.executor.Run(tabCtx, chromedp.SendKeys(selector, textStr, chromedp.ByQuery))
	if err != nil {
		return "", fmt.Errorf("failed to type into selector %q: %w", selector, err)
	}

	return "typed", nil
}
