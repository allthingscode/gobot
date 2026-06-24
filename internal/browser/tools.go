package browser

import (
	"context"
	"fmt"
	"time"

	"github.com/chromedp/chromedp"
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
