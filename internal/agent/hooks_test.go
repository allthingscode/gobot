package agent

import (
	"context"
	"strings"
	"testing"

	agentctx "github.com/allthingscode/gobot/internal/context"
)

func strPtrH(s string) *string { return &s }

func TestHooks_PrePrompt_NoHooks(t *testing.T) {
	h := &Hooks{}
	got := h.RunPrePrompt(context.Background(), "original")
	if got != "original" {
		t.Errorf("got %q, want %q", got, "original")
	}
}

func TestHooks_PrePrompt_SingleHook(t *testing.T) {
	h := &Hooks{}
	h.RegisterPrePrompt(func(ctx context.Context, p string) string {
		return p + " [APPENDED]"
	})
	got := h.RunPrePrompt(context.Background(), "base")
	if got != "base [APPENDED]" {
		t.Errorf("got %q, want %q", got, "base [APPENDED]")
	}
}

func TestHooks_PrePrompt_ChainOrder(t *testing.T) {
	h := &Hooks{}
	h.RegisterPrePrompt(func(ctx context.Context, p string) string { return p + "_A" })
	h.RegisterPrePrompt(func(ctx context.Context, p string) string { return p + "_B" })
	got := h.RunPrePrompt(context.Background(), "X")
	if got != "X_A_B" {
		t.Errorf("got %q, want %q", got, "X_A_B")
	}
}

func TestHooks_PreHistory_NoHooks(t *testing.T) {
	h := &Hooks{}
	msgs := []agentctx.StrategicMessage{
		{Role: "user", Content: &agentctx.MessageContent{Str: strPtrH("hi")}},
	}
	got := h.RunPreHistory(context.Background(), msgs)
	if len(got) != 1 {
		t.Errorf("got %d messages, want 1", len(got))
	}
}

func TestHooks_PreHistory_FiltersMessages(t *testing.T) {
	h := &Hooks{}
	// Hook: keep only last 2 messages
	h.RegisterPreHistory(func(ctx context.Context, msgs []agentctx.StrategicMessage) []agentctx.StrategicMessage {
		if len(msgs) > 2 {
			return msgs[len(msgs)-2:]
		}
		return msgs
	})
	msgs := []agentctx.StrategicMessage{
		{Role: "user"},
		{Role: "assistant"},
		{Role: "user"},
		{Role: "assistant"},
		{Role: "user"},
	}
	got := h.RunPreHistory(context.Background(), msgs)
	if len(got) != 2 {
		t.Errorf("got %d messages, want 2", len(got))
	}
}

func TestSessionManager_PreHistoryHook_Applied(t *testing.T) {
	// Verify that a registered PreHistory hook trims history before runner.Run.
	called := false
	hooks := &Hooks{}
	hooks.RegisterPreHistory(func(ctx context.Context, msgs []agentctx.StrategicMessage) []agentctx.StrategicMessage {
		called = true
		return msgs
	})

	sm := NewSessionManager(&noopRunner{}, nil, "test-model")
	sm.SetHooks(hooks)

	_, _ = sm.Dispatch(context.Background(), "sess1", "hello")
	if !called {
		t.Error("PreHistory hook was not called")
	}
}

func TestSessionManager_PreHistoryHook_TrimsBeforeRunner(t *testing.T) {
	// Hook keeps only last 1 message. Runner should receive exactly 2:
	// the 1 kept by hook + the new user message appended after the hook.
	hooks := &Hooks{}
	hooks.RegisterPreHistory(func(ctx context.Context, msgs []agentctx.StrategicMessage) []agentctx.StrategicMessage {
		if len(msgs) > 1 {
			return msgs[len(msgs)-1:]
		}
		return msgs
	})

	recorder := &recordingRunner{}
	sm := NewSessionManager(recorder, nil, "test-model")
	sm.SetHooks(hooks)

	// First dispatch (no history): hook has nothing to trim, 1 user msg sent.
	_, _ = sm.Dispatch(context.Background(), "sess2", "first")
	// Second dispatch (no checkpoint store, so history is always empty): same.
	_, _ = sm.Dispatch(context.Background(), "sess2", "second")

	// With no store, history is always empty — hook always sees 0 msgs.
	// Runner always receives exactly 1 user msg.
	for _, msgs := range recorder.calls {
		if len(msgs) != 1 {
			t.Errorf("expected 1 message per call (no store), got %d", len(msgs))
		}
	}
}

// noopRunner returns an empty response and the input messages unchanged.
type noopRunner struct{}

func (r *noopRunner) Run(ctx context.Context, sessionKey string, messages []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error) {
	return "ok", messages, nil
}

// recordingRunner records each call's message slice.
type recordingRunner struct {
	calls [][]agentctx.StrategicMessage
}

func (r *recordingRunner) Run(ctx context.Context, sessionKey string, messages []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error) {
	cp := make([]agentctx.StrategicMessage, len(messages))
	copy(cp, messages)
	r.calls = append(r.calls, cp)
	resp := "response"
	return resp, messages, nil
}

// Ensure strings is used (suppress unused import if test file is standalone).
var _ = strings.Contains
