package browser_test

import (
	"context"
	"testing"
	"time"

	"github.com/chromedp/chromedp"

	"github.com/allthingscode/gobot/internal/browser"
)

type dynamicWaitMockExec struct {
	runCount int
}

func (m *dynamicWaitMockExec) Run(ctx context.Context, actions ...chromedp.Action) error {
	m.runCount++
	_ = ctx
	_ = actions
	return nil
}

func TestWaitForDynamicContentBounded_Completes(t *testing.T) {
	t.Parallel()
	exec := &dynamicWaitMockExec{}
	result, err := browser.WaitForDynamicContentBounded(context.Background(), exec, "body", 2, 2*time.Second)
	if err != nil {
		t.Fatalf("WaitForDynamicContentBounded returned error: %v", err)
	}
	if !result.Completed {
		t.Fatalf("expected completed=true, got false")
	}
	if result.Attempts < 1 || result.Attempts > 2 {
		t.Fatalf("attempts out of range: %d", result.Attempts)
	}
}
