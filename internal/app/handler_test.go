//nolint:testpackage // intentionally uses unexported helpers from main package
package app

import (
	"context"
	"testing"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/memory"
)

func TestDispatchHandler_maybeHandleAdminCommand(t *testing.T) {
	t.Parallel()
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
	results, _ := memStore.Search("user message", "sess", 10)
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
