package browser_test

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/chromedp/chromedp"

	"github.com/allthingscode/gobot/internal/browser"
)

func TestExtractExecute_DeterministicSelectorOrder(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	tool := browser.NewExtractTool(browser.NewClientForTest(ctx, cancel))
	tool.SetExecutor(&mockExtractExec{})
	tool.SetExtractFunc(func(ctx context.Context, limit int, selector string) ([]string, error) {
		_ = ctx
		_ = limit
		_ = selector
		return nil, errors.New("eval failed")
	})

	_, err := tool.Execute(context.Background(), "s", "u", map[string]any{
		"url":              "https://example.com/news",
		"wait_selector":    "body",
		"extract_selector": ".custom",
		"goal":             "article",
		"page_map": map[string]any{
			"has_list": true,
		},
	})
	if err == nil {
		t.Fatal("expected terminal error")
	}
	got := err.Error()
	wantOrder := ".custom, article p, main p, .article-content p"
	if !strings.Contains(got, wantOrder) {
		t.Fatalf("error did not include deterministic selector order. got: %q want substring: %q", got, wantOrder)
	}
}

func TestExtractExecute_QualityGateDedupes(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	tool := browser.NewExtractTool(browser.NewClientForTest(ctx, cancel))
	tool.SetExecutor(&mockExtractExec{})
	tool.SetExtractFunc(func(ctx context.Context, limit int, selector string) ([]string, error) {
		_ = ctx
		_ = limit
		_ = selector
		return []string{" ", "a", "Hello", "hello", strings.Repeat("x", 301)}, nil
	})

	res, err := tool.Execute(context.Background(), "s", "u", map[string]any{
		"url":           "https://example.com",
		"wait_selector": "body",
		"goal":          "headline",
	})
	if err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !strings.Contains(res, `"items":["Hello"]`) {
		t.Fatalf("expected deduped high-quality item in payload, got: %s", res)
	}
}

type mockExtractExec struct{}

func (m *mockExtractExec) Run(ctx context.Context, actions ...chromedp.Action) error {
	_ = ctx
	_ = actions
	return nil
}
