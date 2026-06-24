package browser

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/chromedp/chromedp"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/provider"
)

type WaitForTool struct {
	client   *Client
	executor Executor
}

// DynamicWaitResult describes the bounded dynamic-content waiting outcome.
type DynamicWaitResult struct {
	Completed  bool
	TimedOut   bool
	Attempts   int
	LastSignal string
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

// WaitForDynamicContentBounded waits for dynamic content with deterministic attempt/time caps.
func WaitForDynamicContentBounded(ctx context.Context, exec Executor, selector string, maxAttempts int, maxTotal time.Duration) (DynamicWaitResult, error) {
	result := DynamicWaitResult{}
	if maxAttempts <= 0 {
		maxAttempts = 3
	}
	if maxTotal <= 0 {
		maxTotal = 6 * time.Second
	}
	waitSelector := strings.TrimSpace(selector)
	if waitSelector == "" {
		waitSelector = "main, article, [role='main'], .content, #content, body"
	}

	totalCtx, cancel := context.WithTimeout(ctx, maxTotal)
	defer cancel()

	for i := 0; i < maxAttempts; i++ {
		if done, err := runDynamicAttempt(totalCtx, exec, waitSelector, i+1, &result); done {
			return result, err
		}
	}
	return result, nil
}

func runDynamicAttempt(totalCtx context.Context, exec Executor, waitSelector string, attempt int, result *DynamicWaitResult) (bool, error) {
	result.Attempts = attempt
	if waitForSelectorVisible(totalCtx, exec, waitSelector) {
		result.Completed = true
		result.LastSignal = "ready"
		return true, nil
	}

	if signal, ok := detectDynamicSignal(totalCtx, exec); ok {
		result.LastSignal = signal
		if signal == "anti_bot_signal" || signal == "auth_signal" {
			return true, nil
		}
	}

	_ = exec.Run(totalCtx, chromedp.Evaluate(`window.scrollBy(0, Math.max(400, Math.floor(window.innerHeight * 0.8)));`, nil))
	if !waitAttemptInterval(totalCtx, result) {
		return true, nil
	}
	return false, nil
}

func waitForSelectorVisible(totalCtx context.Context, exec Executor, waitSelector string) bool {
	perAttemptCtx, perAttemptCancel := context.WithTimeout(totalCtx, 1500*time.Millisecond)
	defer perAttemptCancel()
	return exec.Run(perAttemptCtx, chromedp.WaitVisible(waitSelector, chromedp.ByQuery)) == nil
}

func detectDynamicSignal(totalCtx context.Context, exec Executor) (string, bool) {
	var signal string
	if err := exec.Run(totalCtx, chromedp.Evaluate(`(() => {
		const text = (document.body && document.body.innerText ? document.body.innerText : "").toLowerCase();
		if (text.includes("captcha") || text.includes("verify you are human") || text.includes("cloudflare")) return "anti_bot_signal";
		if (text.includes("log in") || text.includes("sign in") || text.includes("authentication required")) return "auth_signal";
		if (document.readyState === "complete") return "ready_state_complete";
		return "dynamic_pending";
	})()`, &signal)); err != nil {
		return "", false
	}
	return signal, true
}

func waitAttemptInterval(totalCtx context.Context, result *DynamicWaitResult) bool {
	timer := time.NewTimer(250 * time.Millisecond)
	defer timer.Stop()

	select {
	case <-totalCtx.Done():
		result.TimedOut = true
		return false
	case <-timer.C:
		return true
	}
}
