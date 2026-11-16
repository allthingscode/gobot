package browser

import (
	"context"
	"fmt"
	"time"

	"github.com/chromedp/chromedp"
)

const defaultToolTimeout = 20 * time.Second

// Action adapts a typed chromedp action to an ordered, mockable step.
type Action interface {
	action() chromedp.Action[chromedp.Void]
}

// VoidAction is a step without a return value.
type VoidAction chromedp.Action[chromedp.Void]

func (a VoidAction) action() chromedp.Action[chromedp.Void] {
	return chromedp.Action[chromedp.Void](a)
}

// ResultAction saves a typed result only after its action succeeds.
// Result must point to the destination owned by the caller.
type ResultAction[T any] struct {
	Task   chromedp.Action[T]
	Result *T
}

func (a ResultAction[T]) action() chromedp.Action[chromedp.Void] {
	return chromedp.Func(func(ctx context.Context, target *chromedp.Target) error {
		value, err := a.Task(ctx, target)
		if err != nil {
			return fmt.Errorf("browser action failed: %w", err)
		}
		*a.Result = value
		return nil
	})
}

// Executor runs ordered actions and permits offline result injection in tests.
type Executor interface {
	Run(ctx context.Context, actions ...Action) error
}

// DefaultExecutor wraps chromedp.Do, preserving results and short-circuiting.
type DefaultExecutor struct{}

func (e DefaultExecutor) Run(ctx context.Context, actions ...Action) error {
	return runActions(ctx, chromedp.Do, actions...)
}

func runActions(ctx context.Context, run func(context.Context, ...chromedp.Action[chromedp.Void]) error, actions ...Action) error {
	steps := make([]chromedp.Action[chromedp.Void], len(actions))
	for i, action := range actions {
		steps[i] = action.action()
	}
	if err := run(ctx, steps...); err != nil {
		return fmt.Errorf("chromedp run failed: %w", err)
	}
	return nil
}
