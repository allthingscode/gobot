package browser

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/chromedp/chromedp"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/provider"
)

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

	tabCtx := t.client.TabContext()
	runCtx, runCancel := context.WithTimeout(tabCtx, defaultToolTimeout)
	defer runCancel()

	var text string
	err := t.executor.Run(runCtx, chromedp.Text(selector, &text, chromedp.ByQuery))
	if err != nil {
		return "", fmt.Errorf("failed to get text for selector %q: %w", selector, err)
	}

	return text, nil
}

type GetTextsTool struct {
	client   *Client
	executor Executor
}

// NewGetTextsTool creates a new instance of the GetTextsTool.
func NewGetTextsTool(c *Client) *GetTextsTool {
	return &GetTextsTool{client: c, executor: DefaultExecutor{}}
}

// SetExecutor is used for testing.
func (t *GetTextsTool) SetExecutor(e Executor) { t.executor = e }

func (t *GetTextsTool) Name() string { return "browser_get_texts" }

type getTextsArgs struct {
	Selector string `json:"selector" schema:"The CSS selector of elements to read."`
	Limit    int    `json:"limit" schema:"Maximum number of elements to return. Defaults to 10."`
}

func (t *GetTextsTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        t.Name(),
		Description: "Return innerText values for all elements matching the CSS selector (JSON array).",
		Parameters:  agent.DeriveSchema(getTextsArgs{}),
	}
}

func (t *GetTextsTool) Execute(ctx context.Context, sessionKey, userID string, args map[string]any) (string, error) {
	selector, _ := args["selector"].(string)
	if strings.TrimSpace(selector) == "" {
		return "", fmt.Errorf("selector is required")
	}

	limit := 10
	if rawLimit, ok := args["limit"].(float64); ok {
		if int(rawLimit) > 0 {
			limit = int(rawLimit)
		}
	}
	if limit > 100 {
		limit = 100
	}

	tabCtx := t.client.TabContext()
	runCtx, runCancel := context.WithTimeout(tabCtx, defaultToolTimeout)
	defer runCancel()

	selectorJSON, err := json.Marshal(selector)
	if err != nil {
		return "", fmt.Errorf("marshal selector: %w", err)
	}
	expr := fmt.Sprintf(`(() => {
  const selector = %s;
  const limit = %d;
  const nodes = Array.from(document.querySelectorAll(selector)).slice(0, limit);
  return nodes.map((n) => (n && n.innerText ? n.innerText.trim() : "")).filter((s) => s.length > 0);
})()`, string(selectorJSON), limit)

	var texts []string
	if err := t.executor.Run(runCtx, chromedp.Evaluate(expr, &texts)); err != nil {
		return "", fmt.Errorf("failed to get texts for selector %q: %w", selector, err)
	}
	if texts == nil {
		texts = []string{}
	}
	out, err := json.Marshal(texts)
	if err != nil {
		return "", fmt.Errorf("marshal texts: %w", err)
	}
	return string(out), nil
}
