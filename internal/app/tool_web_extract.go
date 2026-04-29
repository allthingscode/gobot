package app

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"path/filepath"
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

// WebExtractTool orchestrates browser navigation and LLM-guided data extraction.
type WebExtractTool struct {
	cfg           *config.Config
	prov          provider.Provider
	model         string
	executor      browser.Executor // for testing
	clientFactory func(config.BrowserConfig) (*browser.Client, error)
	stateMgr      *state.Manager
}

func newWebExtractTool(cfg *config.Config, prov provider.Provider, model string) *WebExtractTool {
	mCfg := state.ManagerConfig{
		StateDir:    filepath.Join(cfg.StorageRoot(), "web_extraction_state"),
		LockTimeout: 30 * time.Second,
		MaxRetries:  3,
	}
	mgr := state.NewManager(mCfg)
	if err := mgr.Init(); err != nil {
		slog.Error("web_extract: failed to initialize state manager", "dir", mCfg.StateDir, "err", err)
	}

	return &WebExtractTool{
		cfg:           cfg,
		prov:          prov,
		model:         model,
		executor:      browser.DefaultExecutor{},
		clientFactory: browser.NewClient,
		stateMgr:      mgr,
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

func (t *WebExtractTool) Name() string { return webExtractToolName }

func (t *WebExtractTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        webExtractToolName,
		Description: "Automatically navigate to a URL and extract specific data based on a natural language goal. Ideal for pages where selectors are unknown.",
		Parameters:  agent.DeriveSchema(webExtractArgs{}),
	}
}

func (t *WebExtractTool) Execute(ctx context.Context, sessionKey, userID string, args map[string]any) (string, error) { //nolint:gocognit,cyclop,funlen // sequential workflow logic
	urlStr, _ := args["url"].(string)
	goal, _ := args["goal"].(string)

	if urlStr == "" {
		return "", fmt.Errorf("web_extract: url is required")
	}
	if goal == "" {
		return "", fmt.Errorf("web_extract: goal is required")
	}

	safeKey := strings.ReplaceAll(sessionKey, ":", "_")
	wfID := state.WorkflowID(fmt.Sprintf("web_extract_%s_%d", safeKey, time.Now().UnixNano()))
	extState := state.WebExtractionState{
		SessionID:   sessionKey,
		URL:         urlStr,
		ActivePhase: state.PhaseNavigate,
		UpdatedAt:   time.Now(),
	}
	initialData, err := json.Marshal(extState)
	if err != nil {
		slog.Error("web_extract: failed to marshal initial state", "err", err)
	}
	if _, err := t.stateMgr.CreateWorkflow(wfID, initialData); err != nil {
		slog.Warn("web_extract: failed to create workflow state", "workflow", wfID, "err", err)
	}
	if err := t.stateMgr.UpdateStatus(wfID, state.StatusRunning); err != nil {
		slog.Warn("web_extract: failed to update status to running", "workflow", wfID, "err", err)
	}

	updatePhase := func(phase state.WebExtractionPhase, selectors []string, errMsg string) {
		extState.ActivePhase = phase
		extState.UpdatedAt = time.Now()
		if selectors != nil {
			extState.LastSelectors = selectors
		}
		extState.LastError = errMsg
		if data, err := json.Marshal(extState); err == nil {
			if wf, err := t.stateMgr.LoadWithRecovery(wfID); err == nil {
				wf.Data = data
				if err := t.stateMgr.SaveCheckpoint(wf); err != nil {
					slog.Warn("web_extract: failed to save checkpoint", "workflow", wfID, "err", err)
				}
			} else {
				slog.Warn("web_extract: failed to load workflow for update", "workflow", wfID, "err", err)
			}
		}
	}

	defer func() {
		if extState.LastError == "" {
			if err := t.stateMgr.UpdateStatus(wfID, state.StatusCompleted); err != nil {
				slog.Warn("web_extract: failed to update status to completed", "workflow", wfID, "err", err)
			}
			if err := t.stateMgr.Archive(wfID); err != nil {
				slog.Warn("web_extract: failed to archive workflow", "workflow", wfID, "err", err)
			}
		} else {
			if err := t.stateMgr.UpdateStatus(wfID, state.StatusFailed); err != nil {
				slog.Warn("web_extract: failed to update status to failed", "workflow", wfID, "err", err)
			}
		}
	}()

	slog.Info("web_extract: starting navigate phase", "session", sessionKey, "url", urlStr)
	client, err := t.initBrowser()
	if err != nil {
		updatePhase(state.PhaseNavigate, nil, err.Error())
		return "", err
	}
	defer client.Close()

	tabCtx := client.TabContext()
	runCtx, cancel := context.WithTimeout(tabCtx, 120*time.Second) // Increased timeout for retries
	defer cancel()

	title, err := t.navigate(runCtx, client, sessionKey, userID, urlStr)
	if err != nil {
		updatePhase(state.PhaseNavigate, nil, err.Error())
		return "", err
	}

	var finalItems []string
	var selectors []string
	maxRetries := 2

	for attempt := 0; attempt <= maxRetries; attempt++ {
		if attempt > 0 {
			slog.Info("web_extract: retrying extraction", "session", sessionKey, "attempt", attempt)
			updatePhase(state.PhaseRetry, selectors, fmt.Sprintf("Retrying extraction (attempt %d/%d)", attempt, maxRetries))
			time.Sleep(1 * time.Second)
		}

		slog.Info("web_extract: starting plan phase", "session", sessionKey, "attempt", attempt)
		updatePhase(state.PhasePlan, nil, "")

		pageMapJSON, err := t.capturePageMap(runCtx)
		if err != nil {
			extState.LastError = fmt.Sprintf("plan failed (capture): %v", err)
			updatePhase(state.PhasePlan, nil, extState.LastError)
			continue
		}

		plan, err := t.getLLMPlan(runCtx, goal, pageMapJSON)
		if err != nil {
			extState.LastError = fmt.Sprintf("plan failed (llm): %v", err)
			updatePhase(state.PhasePlan, nil, extState.LastError)
			continue
		}

		if plan.Selector != "" {
			selectors = []string{plan.Selector}
		} else {
			selectors = nil
		}

		slog.Info("web_extract: starting extract phase", "session", sessionKey, "selector", plan.Selector)
		updatePhase(state.PhaseExtract, selectors, "")

		finalItems, err = t.performExtraction(runCtx, client, plan, sessionKey, userID)
		if err != nil {
			extState.LastError = fmt.Sprintf("extraction failed: %v", err)
			updatePhase(state.PhaseExtract, selectors, extState.LastError)
			continue
		}

		if len(finalItems) > 0 {
			extState.LastError = "" // Clear error on success
			break
		}

		extState.LastError = "No items found with current plan"
		updatePhase(state.PhaseExtract, selectors, extState.LastError)
	}

	if len(finalItems) == 0 {
		extState.LastError = "" // Clear error so the tool is marked as completed/archived even if no items were found
		return "No items matching the goal were found on the page.", nil
	}

	slog.Info("web_extract: starting summarize phase", "session", sessionKey)
	updatePhase(state.PhaseSummarize, selectors, "")

	summary, err := t.summarizeResults(runCtx, goal, finalItems)
	if err != nil {
		// Non-critical failure: return raw data if summarization fails
		updatePhase(state.PhaseSummarize, selectors, err.Error())
		return t.formatResponse(title, finalItems, "Extraction complete (summary failed)"), nil
	}

	return t.formatResponse(title, finalItems, summary), nil
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
