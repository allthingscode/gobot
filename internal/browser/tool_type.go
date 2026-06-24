package browser

import (
	"context"
	"fmt"
	"strings"

	"github.com/chromedp/chromedp"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/provider"
)

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

	tabCtx := t.client.TabContext()
	runCtx, runCancel := context.WithTimeout(tabCtx, defaultToolTimeout)
	defer runCancel()

	err := t.executor.Run(runCtx, chromedp.SendKeys(selector, textStr, chromedp.ByQuery))
	if err != nil {
		return "", fmt.Errorf("failed to type into selector %q: %w", selector, err)
	}

	return "typed", nil
}
