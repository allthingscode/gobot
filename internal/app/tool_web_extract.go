package app

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/browser"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/provider"
	"github.com/allthingscode/gobot/internal/state"
	"github.com/chromedp/chromedp"
)

const webExtractToolName = "web_extract"

const (
	constraintNone           = "none"
	constraintAuthRequired   = "auth_required"
	constraintAntiBotBlocked = "anti_bot_blocked"
	constraintDynamicPending = "dynamic_pending"
	constraintUnsupported    = "unsupported"
)

// WebExtractTool orchestrates browser navigation and LLM-guided data extraction.
type WebExtractTool struct {
	cfg           *config.Config
	prov          provider.Provider
	model         string
	executor      browser.Executor // for testing
	clientFactory func(config.BrowserConfig) (*browser.Client, error)
}

func newWebExtractTool(cfg *config.Config, prov provider.Provider, model string) *WebExtractTool {
	return &WebExtractTool{
		cfg:           cfg,
		prov:          prov,
		model:         model,
		executor:      browser.DefaultExecutor{},
		clientFactory: browser.NewClient,
	}
}

type webExtractArgs struct {
	URL  string `json:"url" schema:"Target website URL to extract data from."`
	Goal string `json:"goal" schema:"Plain-English description of what to extract (e.g., 'top 5 news titles')."`
}

type webExtractPlan struct {
	Selector  string   `json:"selector"`
	Data      []string `json:"data"`
	Summary   string   `json:"summary"`
	Reasoning string   `json:"reasoning"`
}

type webConstraintPayload struct {
	Status         string `json:"status"`
	Classification string `json:"classification"`
	LastSignal     string `json:"last_signal"`
	Retryable      bool   `json:"retryable"`
	Guidance       string `json:"guidance"`
}

type pageExtractionContext struct {
	client      *browser.Client
	runCtx      context.Context
	cancelRun   context.CancelFunc
	pageTitle   string
	pageMapJSON string
}

func (t *WebExtractTool) Name() string { return webExtractToolName }

func (t *WebExtractTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        webExtractToolName,
		Description: "Automatically navigate to a URL and extract specific data based on a natural language goal. Ideal for pages where selectors are unknown.",
		Parameters:  agent.DeriveSchema(webExtractArgs{}),
	}
}

func (t *WebExtractTool) Execute(ctx context.Context, sessionKey, userID string, args map[string]any) (string, error) {
	urlStr, goal, err := parseWebExtractArgs(args)
	if err != nil {
		return "", err
	}
	pageCtx, err := t.preparePageContext(ctx, sessionKey, userID, urlStr)
	if err != nil {
		return "", err
	}
	defer pageCtx.client.Close()
	defer pageCtx.cancelRun()
	if payload, blocked := t.classifyAndPersistConstraint(pageCtx.runCtx, sessionKey, pageCtx.pageTitle, pageCtx.pageMapJSON); blocked {
		return payload, nil
	}

	plan, err := t.getLLMPlan(pageCtx.runCtx, goal, pageCtx.pageMapJSON)
	if err != nil {
		return "", err
	}

	finalItems, err := t.performExtraction(pageCtx.runCtx, pageCtx.client, plan, sessionKey, userID)
	if err != nil {
		return "", err
	}

	if len(finalItems) == 0 {
		return "No items matching the goal were found on the page.", nil
	}

	summary, err := t.summarizeResults(pageCtx.runCtx, goal, finalItems)
	if err != nil {
		// Non-critical failure: return raw data if summarization fails
		return t.formatResponse(pageCtx.pageTitle, finalItems, "Extraction complete (summary failed)"), nil
	}

	return t.formatResponse(pageCtx.pageTitle, finalItems, summary), nil
}

func parseWebExtractArgs(args map[string]any) (urlStr, goal string, err error) {
	urlStr, _ = args["url"].(string)
	goal, _ = args["goal"].(string)
	if urlStr == "" {
		return "", "", fmt.Errorf("web_extract: url is required")
	}
	if goal == "" {
		return "", "", fmt.Errorf("web_extract: goal is required")
	}
	return urlStr, goal, nil
}

func (t *WebExtractTool) preparePageContext(ctx context.Context, sessionKey, userID, urlStr string) (pageExtractionContext, error) {
	client, err := t.initBrowser()
	if err != nil {
		return pageExtractionContext{}, err
	}
	tabCtx := client.TabContext()
	runCtx, cancel := context.WithTimeout(tabCtx, 60*time.Second)
	title, err := t.navigate(runCtx, client, sessionKey, userID, urlStr)
	if err != nil {
		cancel()
		return pageExtractionContext{}, err
	}
	pageMapJSON, err := t.capturePageMap(runCtx)
	if err != nil {
		cancel()
		return pageExtractionContext{}, err
	}
	return pageExtractionContext{
		client:      client,
		runCtx:      runCtx,
		cancelRun:   cancel,
		pageTitle:   title,
		pageMapJSON: pageMapJSON,
	}, nil
}

func (t *WebExtractTool) classifyAndPersistConstraint(ctx context.Context, sessionKey, title, pageMapJSON string) (string, bool) {
	waitResult, err := browser.WaitForDynamicContentBounded(ctx, t.executor, "", 4, 8*time.Second)
	if err != nil {
		return marshalConstraintPayload(constraintDynamicPending, "dynamic_wait_error"), true
	}
	classification, signal := classifyPageConstraint(title, pageMapJSON, waitResult)
	t.persistConstraintSignal(sessionKey, classification, signal)
	if classification == constraintNone {
		return "", false
	}
	return marshalConstraintPayload(classification, signal), true
}

func (t *WebExtractTool) initBrowser() (*browser.Client, error) {
	if t.cfg.Browser.DebugPort == 0 && !t.cfg.Browser.Headless {
		return nil, fmt.Errorf("web_extract: browser not configured")
	}
	client, err := t.clientFactory(t.cfg.Browser)
	if err != nil {
		return nil, fmt.Errorf("web_extract: browser init: %w", err)
	}
	return client, nil
}

func (t *WebExtractTool) navigate(ctx context.Context, client *browser.Client, sessionKey, userID, urlStr string) (string, error) {
	navTool := browser.NewNavigateTool(client)
	navTool.SetExecutor(t.executor)
	title, err := navTool.Execute(ctx, sessionKey, userID, map[string]any{"url": urlStr})
	if err != nil {
		return "", fmt.Errorf("web_extract: navigation: %w", err)
	}
	return title, nil
}

func (t *WebExtractTool) capturePageMap(ctx context.Context) (string, error) {
	// We extract links, headers, and top text to give the LLM context.
	// We also include aria-label as suggested by minor review comment.
	pageMapExpr := `(() => {
		const map = {
			title: document.title,
			headings: Array.from(document.querySelectorAll('h1, h2, h3')).slice(0, 10).map(h => ({
				text: h.innerText.trim(),
				aria: h.getAttribute('aria-label') || ''
			})),
			links: Array.from(document.querySelectorAll('a')).slice(0, 15).map(l => ({
				text: l.innerText.trim(),
				href: l.href,
				aria: l.getAttribute('aria-label') || ''
			})).filter(l => l.text.length > 0 || l.aria.length > 0),
			snippet: document.body.innerText.slice(0, 1500).trim()
		};
		return JSON.stringify(map);
	})()`

	var pageMapJSON string
	if err := t.executor.Run(ctx, chromedp.Evaluate(pageMapExpr, &pageMapJSON)); err != nil {
		return "", fmt.Errorf("web_extract: page mapping: %w", err)
	}
	return pageMapJSON, nil
}

func (t *WebExtractTool) getLLMPlan(ctx context.Context, goal, pageMapJSON string) (webExtractPlan, error) {
	planPrompt := fmt.Sprintf(`You are a web extraction specialist.
Goal: %s
Page Context (JSON): %s

Based on the goal and page context, identify the BEST CSS selector to extract the target items.
If the goal is to extract a list, provide a single CSS selector that matches each item container or the text elements.

Return ONLY a JSON object:
{
  "selector": "css-selector-here",
  "reasoning": "brief explanation"
}
If the data is already fully present in the snippet and no further extraction is needed, you may return:
{
  "data": ["item1", "item2"],
  "summary": "found items directly"
}`, goal, pageMapJSON)

	planResp, err := t.prov.Chat(ctx, provider.ChatRequest{
		Model: t.model,
		Messages: []agentctx.StrategicMessage{
			{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: &planPrompt}},
		},
	})
	if err != nil {
		return webExtractPlan{}, fmt.Errorf("web_extract: llm planning: %w", err)
	}

	planText := planResp.Message.Content.String()
	plan, err := t.parsePlan(planText)
	if err != nil {
		return webExtractPlan{}, fmt.Errorf("web_extract: parse llm plan: %w", err)
	}
	return plan, nil
}

func (t *WebExtractTool) parsePlan(planText string) (webExtractPlan, error) {
	var plan webExtractPlan
	if err := json.Unmarshal([]byte(planText), &plan); err == nil {
		return plan, nil
	}

	// Fallback: try to find JSON in the response if the model included conversational filler
	start := strings.Index(planText, "{")
	end := strings.LastIndex(planText, "}")
	if start != -1 && end != -1 && end > start {
		if err := json.Unmarshal([]byte(planText[start:end+1]), &plan); err == nil {
			return plan, nil
		}
	}
	return plan, fmt.Errorf("invalid JSON from LLM: %q", planText)
}

func (t *WebExtractTool) performExtraction(ctx context.Context, client *browser.Client, plan webExtractPlan, sessionKey, userID string) ([]string, error) {
	var finalItems []string
	if plan.Selector != "" {
		extractTool := browser.NewGetTextsTool(client)
		extractTool.SetExecutor(t.executor)
		itemsJSON, err := extractTool.Execute(ctx, sessionKey, userID, map[string]any{
			"selector": plan.Selector,
			"limit":    20,
		})
		if err != nil {
			return nil, fmt.Errorf("web_extract: extraction: %w", err)
		}
		_ = json.Unmarshal([]byte(itemsJSON), &finalItems)
	} else if len(plan.Data) > 0 {
		finalItems = plan.Data
	}
	return finalItems, nil
}

func (t *WebExtractTool) summarizeResults(ctx context.Context, goal string, finalItems []string) (string, error) {
	summaryPrompt := fmt.Sprintf(`Extracted Items for goal "%s":
%s

Provide a concise natural language summary of these results.`, goal, strings.Join(finalItems, "\n"))

	summaryResp, err := t.prov.Chat(ctx, provider.ChatRequest{
		Model: t.model,
		Messages: []agentctx.StrategicMessage{
			{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: &summaryPrompt}},
		},
	})
	if err != nil {
		return "", fmt.Errorf("web_extract: summarization: %w", err)
	}
	return summaryResp.Message.Content.String(), nil
}

func (t *WebExtractTool) formatResponse(title string, items []string, summary string) string {
	payload := map[string]any{
		"page_title": title,
		"items":      items,
		"summary":    summary,
	}
	b, _ := json.Marshal(payload)
	return string(b)
}

func (t *WebExtractTool) persistConstraintSignal(sessionKey, classification, signal string) {
	if err := state.SavePageConstraintSignal(t.cfg.StorageRoot(), sessionKey, classification, signal); err != nil {
		slog.Warn("web_extract: failed to persist page constraint signal", "session", sessionKey, "classification", classification, "err", err)
	}
}

func classifyPageConstraint(title, pageMapJSON string, waitResult browser.DynamicWaitResult) (classification, signal string) {
	titleLower := strings.ToLower(strings.TrimSpace(title))
	snippetLower := strings.ToLower(pageSnippet(pageMapJSON))
	fullText := titleLower + " " + snippetLower

	if classification, signal, ok := classifyTerminalConstraint(fullText, waitResult.LastSignal); ok {
		return classification, signal
	}
	if waitResult.TimedOut || !waitResult.Completed {
		return constraintDynamicPending, "dynamic_wait_timeout"
	}
	return constraintNone, constraintNone
}

func classifyTerminalConstraint(fullText, lastSignal string) (classification, signal string, ok bool) {
	if isAntiBotSignal(fullText, lastSignal) {
		return constraintAntiBotBlocked, "anti_bot_signal", true
	}
	if isAuthSignal(fullText, lastSignal) {
		return constraintAuthRequired, "auth_signal", true
	}
	if containsAny(fullText, "unsupported browser", "javascript required", "enable javascript") {
		return constraintUnsupported, "unsupported_runtime", true
	}
	return "", "", false
}

func isAntiBotSignal(fullText, lastSignal string) bool {
	return containsAny(fullText, "captcha", "verify you are human", "access denied", "cloudflare") || lastSignal == "anti_bot_signal"
}

func isAuthSignal(fullText, lastSignal string) bool {
	return containsAny(fullText, "log in", "sign in", "authentication required", "please login") || lastSignal == "auth_signal"
}

func pageSnippet(pageMapJSON string) string {
	var page map[string]any
	if err := json.Unmarshal([]byte(pageMapJSON), &page); err != nil {
		return ""
	}
	snippet, _ := page["snippet"].(string)
	return snippet
}

func containsAny(s string, needles ...string) bool {
	for _, n := range needles {
		if strings.Contains(s, n) {
			return true
		}
	}
	return false
}

func marshalConstraintPayload(classification, signal string) string {
	payload := webConstraintPayload{
		Status:         "constraint_blocked",
		Classification: classification,
		LastSignal:     signal,
		Retryable:      classification == constraintDynamicPending,
		Guidance:       guidanceForClassification(classification),
	}
	b, _ := json.Marshal(payload)
	return string(b)
}

func guidanceForClassification(classification string) string {
	switch classification {
	case constraintAuthRequired:
		return "This page appears to require authentication. Sign in through browser tools first, then retry extraction."
	case constraintAntiBotBlocked:
		return "This page appears protected by anti-bot controls (captcha/challenge). Automated extraction is blocked; complete the challenge manually, then retry."
	case constraintDynamicPending:
		return "The page appears to still be loading dynamic content. Retry extraction after additional wait or interaction."
	case constraintUnsupported:
		return "This page requires runtime capabilities that are not supported in the current extraction flow."
	default:
		return "No page constraints detected."
	}
}
