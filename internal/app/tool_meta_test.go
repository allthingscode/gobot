//nolint:testpackage // requires unexported tool-meta internals (formatToolMetaBlock, withToolMeta, toolMetaFromCtx)
package app

import (
	"context"
	"strings"
	"sync"
	"testing"
)

func TestFormatToolMetaBlock_NilMeta(t *testing.T) {
	t.Parallel()
	if got := formatToolMetaBlock("body", nil); got != "body" {
		t.Errorf("nil meta: want unchanged %q, got %q", "body", got)
	}
}

func TestFormatToolMetaBlock_EmptyMeta(t *testing.T) {
	t.Parallel()
	if got := formatToolMetaBlock("body", &ToolMeta{}); got != "body" {
		t.Errorf("empty meta: want unchanged %q, got %q", "body", got)
	}
}

func TestFormatToolMetaBlock_OrderedKnownKeysOnly(t *testing.T) {
	t.Parallel()
	m := &ToolMeta{}
	// Insert out of order and include an unknown key that must be dropped.
	m.Set("iterations", "3")
	m.Set("agent_type", "coder")
	m.Set("unknown", "leak")
	m.Set("model", "opus")

	got := formatToolMetaBlock("RESULT", m)
	want := "RESULT\n\n[tool_meta]\nagent_type: coder\nmodel: opus\niterations: 3\n[/tool_meta]"
	if got != want {
		t.Errorf("formatted block mismatch:\n got: %q\nwant: %q", got, want)
	}
	if strings.Contains(got, "unknown") || strings.Contains(got, "leak") {
		t.Errorf("unknown key leaked into block: %q", got)
	}
}

func TestWithToolMeta_RoundTrip(t *testing.T) {
	t.Parallel()
	ctx, m := withToolMeta(context.Background())
	if m == nil {
		t.Fatal("withToolMeta returned nil meta")
	}
	if got := toolMetaFromCtx(ctx); got != m {
		t.Errorf("toolMetaFromCtx did not return the injected meta: got %p want %p", got, m)
	}
}

func TestToolMetaFromCtx_Absent(t *testing.T) {
	t.Parallel()
	if got := toolMetaFromCtx(context.Background()); got != nil {
		t.Errorf("expected nil meta for ctx without value, got %v", got)
	}
}

func TestToolMeta_ConcurrentSet(t *testing.T) {
	t.Parallel()
	m := &ToolMeta{}
	keys := []string{"agent_type", "model", "provider", "elapsed_ms", "iterations"}

	var wg sync.WaitGroup
	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func(k string) {
			defer wg.Done()
			m.Set(k, "v")
		}(keys[i%len(keys)])
	}
	wg.Wait()

	got := formatToolMetaBlock("R", m)
	for _, k := range keys {
		if !strings.Contains(got, k+": v") {
			t.Errorf("concurrent Set lost key %q: %q", k, got)
		}
	}
}
