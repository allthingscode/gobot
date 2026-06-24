package browser

import (
	"context"
	"fmt"
	"strings"

	"github.com/chromedp/chromedp"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/provider"
)

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

	tabCtx := t.client.TabContext()
	runCtx, runCancel := context.WithTimeout(tabCtx, defaultToolTimeout)
	defer runCancel()

	err := t.executor.Run(runCtx, chromedp.Click(selector, chromedp.ByQuery))
	if err != nil {
		return "", fmt.Errorf("failed to click selector %q: %w", selector, err)
	}

	return "clicked", nil
}
