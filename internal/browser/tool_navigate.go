package browser

import (
	"context"
	"fmt"

	"github.com/chromedp/chromedp"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/provider"
)

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

	tabCtx := t.client.TabContext()
	runCtx, runCancel := context.WithTimeout(tabCtx, defaultToolTimeout)
	defer runCancel()

	var title string
	err := t.executor.Run(runCtx,
		chromedp.Navigate(urlStr),
		chromedp.Title(&title),
	)
	if err != nil {
		return "", fmt.Errorf("failed to navigate: %w", err)
	}

	return title, nil
}
