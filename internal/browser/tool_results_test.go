package browser_test

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/browser"
)

type resultExecutor struct {
	err error
}

func (e resultExecutor) Run(ctx context.Context, actions ...browser.Action) error {
	if e.err != nil {
		return e.err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	for _, action := range actions {
		switch step := action.(type) {
		case browser.ResultAction[string]:
			*step.Result = "Page title or text"
		case browser.ResultAction[[]string]:
			*step.Result = []string{"First item", "Second item"}
		case browser.ResultAction[[]byte]:
			*step.Result = []byte{0xff, 0xd8, 1}
		}
	}
	return nil
}

func TestToolResultPropagation(t *testing.T) {
	t.Parallel()
	for _, tt := range []toolTest{
		{toolName: "browser_navigate", args: map[string]any{"url": "https://example.invalid"}, wantResult: "Page title or text"},
		{toolName: "browser_get_text", args: map[string]any{"selector": "#main > h1"}, wantResult: "Page title or text"},
		{toolName: "browser_get_texts", args: map[string]any{"selector": "a[data-name=\"hello\"]"}, wantResult: `["First item","Second item"]`},
		{toolName: "browser_screenshot", args: map[string]any{}, wantResult: "/9gB"},
		{toolName: "browser_extract", args: map[string]any{"url": "https://example.invalid", "wait_selector": "main > h1", "extract_selector": ".item"}, wantResult: `"title":"Page title or text"`},
		{toolName: "browser_click", args: map[string]any{"selector": "button[data-label='go']"}, wantResult: "clicked"},
		{toolName: "browser_type", args: map[string]any{"selector": "#search", "text": "hello"}, wantResult: "typed"},
		{toolName: "browser_wait_for", args: map[string]any{"selector": "main > h1"}, wantResult: "ready"},
	} {
		t.Run(tt.toolName, func(t *testing.T) {
			t.Parallel()
			for _, fail := range []bool{false, true} {
				checkToolResult(t, tt, fail)
			}
		})
	}
}

func checkToolResult(t *testing.T, tt toolTest, fail bool) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	client := browser.NewClientForTest(ctx, cancel)
	defer client.Close()
	tool := getTool(tt, client)
	sentinel := errors.New("executor failed")
	exec := resultExecutor{}
	if fail {
		exec.err = sentinel
	}
	tool.(interface{ SetExecutor(browser.Executor) }).SetExecutor(exec)
	got, err := tool.Execute(context.Background(), "session", "user", tt.args)
	if fail {
		if !errors.Is(err, sentinel) {
			t.Fatalf("error = %v; want wrapped executor error", err)
		}
		return
	}
	if err != nil || !strings.Contains(got, tt.wantResult) {
		t.Fatalf("result = %q, %v; want %q", got, err, tt.wantResult)
	}
}

type blockingExecutor struct{}

func (blockingExecutor) Run(ctx context.Context, _ ...browser.Action) error {
	<-ctx.Done()
	return ctx.Err()
}

func TestWaitForCancellationAndDeadline(t *testing.T) {
	t.Parallel()
	for _, name := range []string{"canceled tab", "tool timeout"} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			client := browser.NewClientForTest(ctx, cancel)
			defer client.Close()
			tool := browser.NewWaitForTool(client)
			tool.SetExecutor(blockingExecutor{})
			want := context.DeadlineExceeded
			if name == "canceled tab" {
				cancel()
				want = context.Canceled
			}
			_, err := tool.Execute(context.Background(), "s", "u", map[string]any{"selector": "#ready", "timeout_millis": float64(1)})
			if !errors.Is(err, want) {
				t.Fatalf("error = %v; want %v", err, want)
			}
		})
	}
}

func TestDynamicWaitCancellation(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	result, err := browser.WaitForDynamicContentBounded(ctx, blockingExecutor{}, "#ready", 2, time.Second)
	if err != nil || !result.TimedOut || result.Completed || result.Attempts != 1 {
		t.Fatalf("canceled wait = %+v, %v", result, err)
	}
}
