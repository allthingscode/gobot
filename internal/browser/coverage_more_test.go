//nolint:testpackage // covers package-private helpers
package browser

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/chromedp/chromedp"
)

type errorExecutor struct{}

func (e errorExecutor) Run(context.Context, ...chromedp.Action) error {
	return errors.New("not visible")
}

func TestWaitDynamicHelpersErrorAndTimeoutBranches(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	result := DynamicWaitResult{}
	if waitAttemptInterval(ctx, &result) {
		t.Fatal("canceled context should stop interval")
	}
	if !result.TimedOut {
		t.Fatal("canceled interval should mark timed out")
	}

	signal, ok := detectDynamicSignal(context.Background(), errorExecutor{})
	if ok || signal != "" {
		t.Fatalf("detectDynamicSignal with executor error = %q/%v", signal, ok)
	}

	done, err := runDynamicAttempt(ctx, errorExecutor{}, "body", 2, &result)
	if err != nil {
		t.Fatalf("runDynamicAttempt should not return executor error, got %v", err)
	}
	if !done || result.Attempts != 2 {
		t.Fatalf("runDynamicAttempt done=%v attempts=%d", done, result.Attempts)
	}
}

func TestExtractTextsReturnsEmptySliceForNilEvaluateResult(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	tool := NewExtractTool(NewClientForTest(ctx, cancel))
	tool.SetExecutor(mockExtractExecutor{})

	items, err := tool.extractTexts(context.Background(), 5, ".headline")
	if err != nil {
		t.Fatalf("extractTexts: %v", err)
	}
	if items == nil || len(items) != 0 {
		t.Fatalf("items = %#v, want empty non-nil slice", items)
	}
}

func TestExtractHelpersAdditionalBranches(t *testing.T) {
	t.Parallel()

	if got := terminalFailureClass(nil); got != retryFailureTerminal {
		t.Fatalf("terminalFailureClass(nil)=%q", got)
	}
	attempts := []selectorAttemptResult{{selector: " ", class: retryFailureEmpty}, {selector: ".a", class: retryFailureEvaluate}}
	if got := compactAttemptedSelectors(attempts, ".b"); strings.Join(got, ",") != ".a,.b" {
		t.Fatalf("compactAttemptedSelectors = %v", got)
	}
	if got := goalSelectorCandidates("unknown"); got != nil {
		t.Fatalf("unknown goal candidates = %v", got)
	}
	input, err := parseExtractInput(map[string]any{
		"url":            "https://example.com",
		"wait_selector":  "body",
		"limit":          float64(500),
		"timeout_millis": float64(70000),
	})
	if err != nil {
		t.Fatalf("parseExtractInput: %v", err)
	}
	if input.Limit != 100 || input.Timeout != 60*time.Second {
		t.Fatalf("capped input = limit %d timeout %s", input.Limit, input.Timeout)
	}
}

type mockExtractExecutor struct{}

func (m mockExtractExecutor) Run(context.Context, ...chromedp.Action) error { return nil }
