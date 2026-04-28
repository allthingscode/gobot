package browser

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/chromedp/chromedp"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/provider"
)

const defaultToolTimeout = 20 * time.Second

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

type WaitForTool struct {
	client   *Client
	executor Executor
}

// NewWaitForTool creates a new instance of the WaitForTool.
func NewWaitForTool(c *Client) *WaitForTool {
	return &WaitForTool{client: c, executor: DefaultExecutor{}}
}

// SetExecutor is used for testing.
func (t *WaitForTool) SetExecutor(e Executor) { t.executor = e }

func (t *WaitForTool) Name() string { return "browser_wait_for" }

type waitForArgs struct {
	Selector      string `json:"selector" schema:"The CSS selector to wait for."`
	TimeoutMillis int    `json:"timeout_millis" schema:"Optional timeout in milliseconds (max 60000). Defaults to 10000."`
}

func (t *WaitForTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        t.Name(),
		Description: "Wait until an element matching the CSS selector exists and is visible.",
		Parameters:  agent.DeriveSchema(waitForArgs{}),
	}
}

func (t *WaitForTool) Execute(ctx context.Context, sessionKey, userID string, args map[string]any) (string, error) {
	selector, _ := args["selector"].(string)
	if strings.TrimSpace(selector) == "" {
		return "", fmt.Errorf("selector is required")
	}

	timeout := 10 * time.Second
	if raw, ok := args["timeout_millis"].(float64); ok {
		ms := int(raw)
		if ms > 0 {
			if ms > 60000 {
				ms = 60000
			}
			timeout = time.Duration(ms) * time.Millisecond
		}
	}

	tabCtx := t.client.TabContext()
	runCtx, runCancel := context.WithTimeout(tabCtx, timeout)
	defer runCancel()

	if err := t.executor.Run(runCtx, chromedp.WaitVisible(selector, chromedp.ByQuery)); err != nil {
		return "", fmt.Errorf("failed to wait for selector %q: %w", selector, err)
	}
	return "ready", nil
}

type ExtractTool struct {
	client    *Client
	executor  Executor
	extractFn func(context.Context, int, string) ([]string, error)
}

// NewExtractTool creates a new instance of the ExtractTool.
func NewExtractTool(c *Client) *ExtractTool {
	t := &ExtractTool{client: c, executor: DefaultExecutor{}}
	t.extractFn = t.extractTexts
	return t
}

// SetExecutor is used for testing.
func (t *ExtractTool) SetExecutor(e Executor) { t.executor = e }

// SetExtractFunc is used for testing retry and quality behavior.
func (t *ExtractTool) SetExtractFunc(fn func(context.Context, int, string) ([]string, error)) {
	if fn != nil {
		t.extractFn = fn
	}
}

func (t *ExtractTool) Name() string { return "browser_extract" }

type extractArgs struct {
	URL           string         `json:"url" schema:"The URL to navigate to before extraction."`
	WaitSelector  string         `json:"wait_selector" schema:"CSS selector to wait for before extraction."`
	ExtractSelect string         `json:"extract_selector" schema:"Preferred CSS selector for extraction. Optional when using goal-based planning."`
	Goal          string         `json:"goal" schema:"Optional extraction goal: headline, article, list, table."`
	PageMap       map[string]any `json:"page_map" schema:"Optional page structure signals (e.g., has_article, has_list, has_table)."`
	Limit         int            `json:"limit" schema:"Maximum number of extracted elements. Defaults to 10."`
	TimeoutMillis int            `json:"timeout_millis" schema:"Optional timeout in milliseconds (max 60000). Defaults to 15000."`
}

type extractInput struct {
	URL             string
	WaitSelector    string
	ExtractSelector string
	Goal            string
	PageMap         map[string]any
	Limit           int
	Timeout         time.Duration
}

type retryFailureClass string

const (
	retryFailureEmpty    retryFailureClass = "empty"
	retryFailureEvaluate retryFailureClass = "evaluate_error"
	retryFailureTimeout  retryFailureClass = "timeout"
	retryFailureTerminal retryFailureClass = "terminal"
)

type selectorAttemptResult struct {
	selector string
	class    retryFailureClass
}

func (t *ExtractTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        t.Name(),
		Description: "Navigate, wait for content, and extract text list in one step. Returns JSON with title and items.",
		Parameters:  agent.DeriveSchema(extractArgs{}),
	}
}

func (t *ExtractTool) Execute(ctx context.Context, sessionKey, userID string, args map[string]any) (string, error) {
	input, err := parseExtractInput(args)
	if err != nil {
		return "", err
	}

	tabCtx := t.client.TabContext()
	runCtx, runCancel := context.WithTimeout(tabCtx, input.Timeout)
	defer runCancel()

	var title string
	if err := t.executor.Run(runCtx, chromedp.Navigate(input.URL), chromedp.Title(&title)); err != nil {
		return "", fmt.Errorf("failed to navigate: %w", err)
	}
	if err := t.executor.Run(runCtx, chromedp.WaitVisible(input.WaitSelector, chromedp.ByQuery)); err != nil {
		return "", fmt.Errorf("failed to wait for selector %q: %w", input.WaitSelector, err)
	}

	selectors := planExtractSelectors(input)
	if len(selectors) == 0 {
		return "", fmt.Errorf("browser_extract: no selectors available for goal %q", input.Goal)
	}

	maxAttempts := min(4, len(selectors))
	attempts, response, err := t.runExtractAttempts(runCtx, selectors[:maxAttempts], input.Limit, title)
	if err == nil {
		return response, nil
	}
	return "", fmt.Errorf("browser_extract: extraction failed after %d/%d attempts (%s): %s", len(attempts), maxAttempts, terminalFailureClass(attempts), strings.Join(compactAttemptedSelectors(attempts, ""), ", "))
}

func (t *ExtractTool) runExtractAttempts(ctx context.Context, selectors []string, limit int, title string) ([]selectorAttemptResult, string, error) {
	attempts := make([]selectorAttemptResult, 0, len(selectors))
	for _, selector := range selectors {
		items, err := t.extractFn(ctx, limit, selector)
		if err != nil {
			class := classifyExtractError(err, ctx.Err())
			attempts = append(attempts, selectorAttemptResult{selector: selector, class: class})
			if class == retryFailureTimeout {
				return attempts, "", fmt.Errorf("retry loop stopped after timeout: %w", err)
			}
			continue
		}
		qualityItems, ok := qualityGateExtractItems(items)
		if !ok {
			attempts = append(attempts, selectorAttemptResult{selector: selector, class: retryFailureEmpty})
			continue
		}
		response, err := buildExtractSuccessPayload(title, qualityItems, selector, attempts)
		if err != nil {
			return attempts, "", err
		}
		return attempts, response, nil
	}
	return attempts, "", fmt.Errorf("all selectors exhausted")
}

func classifyExtractError(err, runErr error) retryFailureClass {
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(runErr, context.DeadlineExceeded) {
		return retryFailureTimeout
	}
	return retryFailureEvaluate
}

func buildExtractSuccessPayload(title string, items []string, selector string, attempts []selectorAttemptResult) (string, error) {
	payload := map[string]any{
		"title":               title,
		"items":               items,
		"selector_used":       selector,
		"attempted_count":     len(attempts) + 1,
		"attempted_selectors": compactAttemptedSelectors(attempts, selector),
	}
	out, marshalErr := json.Marshal(payload)
	if marshalErr != nil {
		return "", fmt.Errorf("marshal extract response: %w", marshalErr)
	}
	return string(out), nil
}

func parseExtractInput(args map[string]any) (extractInput, error) {
	urlStr, _ := args["url"].(string)
	waitSelector, _ := args["wait_selector"].(string)
	extractSelector, _ := args["extract_selector"].(string)
	if strings.TrimSpace(urlStr) == "" {
		return extractInput{}, fmt.Errorf("url is required")
	}
	if strings.TrimSpace(waitSelector) == "" {
		return extractInput{}, fmt.Errorf("wait_selector is required")
	}
	limit := 10
	if rawLimit, ok := args["limit"].(float64); ok && int(rawLimit) > 0 {
		limit = int(rawLimit)
	}
	if limit > 100 {
		limit = 100
	}

	timeout := 15 * time.Second
	if raw, ok := args["timeout_millis"].(float64); ok {
		ms := int(raw)
		if ms > 0 {
			if ms > 60000 {
				ms = 60000
			}
			timeout = time.Duration(ms) * time.Millisecond
		}
	}

	return extractInput{
		URL:             urlStr,
		WaitSelector:    waitSelector,
		ExtractSelector: extractSelector,
		Goal:            parseOptionalString(args, "goal"),
		PageMap:         extractPageMap(args["page_map"]),
		Limit:           limit,
		Timeout:         timeout,
	}, nil
}

func parseOptionalString(args map[string]any, key string) string {
	v, _ := args[key].(string)
	return strings.ToLower(strings.TrimSpace(v))
}

func extractPageMap(raw any) map[string]any {
	pm, ok := raw.(map[string]any)
	if !ok || pm == nil {
		return map[string]any{}
	}
	return pm
}

func planExtractSelectors(in extractInput) []string {
	candidates := make([]string, 0, 16)
	add := func(list ...string) {
		for _, s := range list {
			trimmed := strings.TrimSpace(s)
			if trimmed != "" {
				candidates = append(candidates, trimmed)
			}
		}
	}
	add(in.ExtractSelector)
	add(goalSelectorCandidates(in.Goal)...)
	add(pageMapSelectorCandidates(in.PageMap)...)
	add(defaultSelectorFallbacks()...)
	return uniqueStringsStable(candidates)
}

func goalSelectorCandidates(goal string) []string {
	switch goal {
	case "headline":
		return []string{"h1", "article h1", "main h1", ".headline", ".post-title"}
	case "article":
		return []string{"article p", "main p", ".article-content p", ".post-content p"}
	case "list":
		return []string{"ul li", "ol li", "[role='listitem']", ".list-item"}
	case "table":
		return []string{"table tr", "table tbody tr", "[role='row']"}
	default:
		return nil
	}
}

func pageMapSelectorCandidates(pm map[string]any) []string {
	candidates := make([]string, 0, 8)
	add := func(flag string, selectors ...string) {
		if pageMapFlag(pm, flag) {
			candidates = append(candidates, selectors...)
		}
	}
	add("has_headline", "h1", ".headline")
	add("has_article", "article p", "main p")
	add("has_list", "ul li", "ol li", ".list-item")
	add("has_table", "table tr", "table tbody tr")
	return candidates
}

func pageMapFlag(pm map[string]any, key string) bool {
	v, ok := pm[key]
	if !ok {
		return false
	}
	switch typed := v.(type) {
	case bool:
		return typed
	case string:
		return strings.EqualFold(strings.TrimSpace(typed), "true")
	default:
		return false
	}
}

func defaultSelectorFallbacks() []string {
	return []string{"article p", "main p", "h1", "h2", "ul li", "table tr"}
}

func uniqueStringsStable(values []string) []string {
	out := make([]string, 0, len(values))
	seen := make(map[string]struct{}, len(values))
	for _, v := range values {
		if _, exists := seen[v]; exists {
			continue
		}
		seen[v] = struct{}{}
		out = append(out, v)
	}
	return out
}

func qualityGateExtractItems(items []string) ([]string, bool) {
	deduped := make([]string, 0, len(items))
	seen := map[string]struct{}{}
	for _, item := range items {
		trimmed := strings.TrimSpace(item)
		if len(trimmed) < 2 || len(trimmed) > 300 {
			continue
		}
		key := strings.ToLower(trimmed)
		if _, exists := seen[key]; exists {
			continue
		}
		seen[key] = struct{}{}
		deduped = append(deduped, trimmed)
	}
	return deduped, len(deduped) > 0
}

func (t *ExtractTool) extractTexts(ctx context.Context, limit int, selector string) ([]string, error) {
	selectorJSON, err := json.Marshal(selector)
	if err != nil {
		return nil, fmt.Errorf("marshal selector: %w", err)
	}
	expr := fmt.Sprintf(`(() => {
  const selector = %s;
  const limit = %d;
  const nodes = Array.from(document.querySelectorAll(selector)).slice(0, limit);
  return nodes.map((n) => (n && n.innerText ? n.innerText.trim() : "")).filter((s) => s.length > 0);
})()`, string(selectorJSON), limit)
	var items []string
	if err := t.executor.Run(ctx, chromedp.Evaluate(expr, &items)); err != nil {
		return nil, fmt.Errorf("failed to get texts for selector %q: %w", selector, err)
	}
	if items == nil {
		items = []string{}
	}
	return items, nil
}

func terminalFailureClass(attempts []selectorAttemptResult) retryFailureClass {
	if len(attempts) == 0 {
		return retryFailureTerminal
	}
	last := attempts[len(attempts)-1]
	return last.class
}

func compactAttemptedSelectors(attempts []selectorAttemptResult, current string) []string {
	out := make([]string, 0, len(attempts)+1)
	for _, a := range attempts {
		if strings.TrimSpace(a.selector) != "" {
			out = append(out, a.selector)
		}
	}
	if strings.TrimSpace(current) != "" {
		out = append(out, current)
	}
	return slices.Clip(out)
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
