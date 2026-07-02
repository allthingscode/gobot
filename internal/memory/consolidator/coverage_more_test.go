//nolint:testpackage // covers package-private helpers
package consolidator

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/observability"
)

type channelRunner struct {
	called chan string
	resp   string
	err    error
}

func (r *channelRunner) RunText(_ context.Context, _, prompt, _ string) (string, error) {
	r.called <- prompt
	return r.resp, r.err
}

func TestConsolidatorConsolidateWithTracerWrapsErrors(t *testing.T) {
	t.Parallel()

	store := newTestStore(t)
	runner := &channelRunner{called: make(chan string, 1), err: errors.New("llm down")}
	c := New(runner, store, nil, nil)
	c.SetTracer(observability.NewDispatchTracer(nil))

	_, err := c.consolidate(context.Background(), "session-1", strings.Repeat("fact ", 30))
	if err == nil || !strings.Contains(err.Error(), "extract facts") || !strings.Contains(err.Error(), "llm down") {
		t.Fatalf("expected wrapped consolidation error, got %v", err)
	}
}

func TestConsolidateAsyncLongReplyTriggersRunner(t *testing.T) {
	t.Parallel()

	store := newTestStore(t)
	runner := &channelRunner{
		called: make(chan string, 1),
		resp:   `[{"fact":"User prefers concise status updates","importance":4}]`,
	}
	c := New(runner, store, nil, nil)

	c.ConsolidateAsync("session-async", strings.Repeat("This reply contains a durable user preference. ", 4))

	select {
	case prompt := <-runner.called:
		if !strings.Contains(prompt, "durable user preference") {
			t.Fatalf("prompt missing reply: %q", prompt)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("ConsolidateAsync did not invoke runner")
	}
}

func TestConsolidatorCustomPromptNewlineBranch(t *testing.T) {
	t.Parallel()

	store := newTestStore(t)
	runner := &channelRunner{
		called: make(chan string, 1),
		resp:   `[]`,
	}
	c := New(runner, store, nil, nil)
	c.SetPrompt("Extract facts")

	n, err := c.consolidate(context.Background(), "session-1", "The user prefers weekly planning summaries.")
	if err != nil {
		t.Fatalf("consolidate: %v", err)
	}
	if n != 0 {
		t.Fatalf("indexed = %d, want 0", n)
	}
	prompt := <-runner.called
	if !strings.Contains(prompt, "Agent reply to consolidate:") {
		t.Fatalf("custom prompt did not append reply heading: %q", prompt)
	}
}
