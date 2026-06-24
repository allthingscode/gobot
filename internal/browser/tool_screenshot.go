package browser

import (
	"context"
	"encoding/base64"
	"fmt"

	"github.com/chromedp/chromedp"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/provider"
)

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
	tabCtx := t.client.TabContext()
	runCtx, runCancel := context.WithTimeout(tabCtx, defaultToolTimeout)
	defer runCancel()

	var buf []byte
	err := t.executor.Run(runCtx, chromedp.FullScreenshot(&buf, 90))
	if err != nil {
		return "", fmt.Errorf("failed to capture screenshot: %w", err)
	}

	return base64.StdEncoding.EncodeToString(buf), nil
}
