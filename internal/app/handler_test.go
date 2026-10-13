//nolint:testpackage // intentionally uses unexported helpers from main package
package app

import (
	"context"
	"fmt"
	"github.com/allthingscode/gobot/internal/memory/consolidator"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/memory"
)

//nolint:paralleltest // uses global state // modifies global breaker registry
func TestDispatchHandler_maybeHandleAdminCommand(t *testing.T) {
	h := &DispatchHandler{}

	reply, ok := h.maybeHandleAdminCommand("sess", "/reset_circuits")
	if !ok || reply == "" {
		t.Error("expected /reset_circuits to be handled")
	}

	reply, ok = h.maybeHandleAdminCommand("sess", "normal message")
	if ok || reply != "" {
		t.Error("did not expect normal message to be handled as admin command")
	}
}

func TestDispatchHandler_Handle(t *testing.T) {
	t.Parallel()
	runner := &mockSubAgentRunner{response: "agent reply"}
	mgr := agent.NewSessionManager(runner, nil, "test-model")
	h := &DispatchHandler{
		Mgr: mgr,
	}

	msg := bot.InboundMessage{
		Text:     "hello",
		ChatID:   123,
		SenderID: 456,
	}

	got, err := h.Handle(context.Background(), "sess", msg)
	if err != nil {
		t.Fatalf("Handle failed: %v", err)
	}
	if got != "agent reply" {
		t.Errorf("Handle got %q, want %q", got, "agent reply")
	}
}

func TestDispatchHandler_indexMemory(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	memStore, err := memory.NewMemoryStore(tmpDir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = memStore.Close()
	}()

	h := &DispatchHandler{
		Memory: memStore,
	}

	h.indexMemory("sess", "user message", "assistant reply")

	// Verify it was indexed
	results, _ := memStore.Search(context.Background(), "user message", "sess", 10)
	if len(results) == 0 {
		t.Error("expected indexed content to be searchable")
	}
}

func TestDispatchHandler_HandleCallback(t *testing.T) {
	t.Parallel()
	h := &DispatchHandler{}

	// Just ensure it doesn't panic with nil Hitl
	_ = h.HandleCallback(context.Background(), bot.InboundCallback{})
}

type handlerConsolidationRunner struct {
	started   chan struct{}
	release   chan struct{}
	ownerSeen chan context.Context
}

func (r handlerConsolidationRunner) RunText(ctx context.Context, _, _, _ string) (string, error) {
	r.ownerSeen <- ctx
	close(r.started)
	<-r.release
	return "[]", nil
}

func TestHandlerConsolidationSurvivesRequest(t *testing.T) {
	t.Parallel()
	for _, reply := range []string{"OK", strings.Repeat("long reply ", 10)} {
		t.Run(fmt.Sprint(len(reply)), func(t *testing.T) {
			t.Parallel()
			checkHandlerConsolidation(t, reply)
		})
	}
}

func checkHandlerConsolidation(t *testing.T, reply string) {
	t.Helper()
	store, err := memory.NewMemoryStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = store.Close() }()
	started, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	defer once.Do(func() { close(release) })
	seen := make(chan context.Context, 1)
	c := consolidator.New(handlerConsolidationRunner{started, release, seen}, store, nil, nil)
	runtime, cancelRuntime := context.WithCancel(context.Background())
	defer cancelRuntime()
	c.BindLifetime(runtime)
	mgr := agent.NewSessionManager(&mockSubAgentRunner{response: reply}, nil, "test-model")
	h := &DispatchHandler{Mgr: mgr, Consolidator: c}
	request, endRequest := context.WithCancel(context.Background())
	defer endRequest()
	result := make(chan error, 1)
	go func() {
		got, err := h.Handle(request, "session", bot.InboundMessage{Text: "hello", ChatID: 123, SenderID: 456})
		if got != reply {
			err = fmt.Errorf("unexpected reply: %s", got)
		}
		result <- err
	}()
	checkHandlerResult(t, result)
	endRequest()
	if len(reply) > 80 {
		awaitAppWorker(t, started)
		if ctx := <-seen; ctx.Err() != nil {
			t.Fatal("request completion cancelled worker")
		}
	}
	finishHandlerConsolidation(t, c, &once, release, started, reply)
}

func checkHandlerResult(t *testing.T, result <-chan error) {
	t.Helper()
	select {
	case err := <-result:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("handler blocked on consolidation")
	}
}

func finishHandlerConsolidation(t *testing.T, c *consolidator.Consolidator, once *sync.Once, release chan struct{}, started <-chan struct{}, reply string) {
	t.Helper()
	once.Do(func() { close(release) })
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := c.Shutdown(ctx); err != nil {
		t.Fatal(err)
	}
	if len(reply) < 80 {
		select {
		case <-started:
			t.Fatal("short reply launched")
		default:
		}
	}
}

func awaitAppWorker(t *testing.T, ch <-chan struct{}) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(2 * time.Second):
		t.Fatal("worker barrier timed out")
	}
}
