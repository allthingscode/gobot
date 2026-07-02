//nolint:testpackage // covers package-private helpers
package bot

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/observability"
)

func TestSessionPrefixHelpersAndUserID(t *testing.T) {
	t.Parallel()

	if !IsCronSession("cron:job") || IsCronSession("telegram:1") {
		t.Fatal("cron session helper mismatch")
	}
	if !IsTelegramSession("telegram:1") || IsTelegramSession("cron:job") {
		t.Fatal("telegram session helper mismatch")
	}
	if got := UserID(123, 456); got != "123" {
		t.Fatalf("DM user id = %q", got)
	}
	if got := UserID(-123, 456); got != "456" {
		t.Fatalf("group user id = %q", got)
	}
}

func TestBotSetTracerAndSendWithButtons(t *testing.T) {
	t.Parallel()

	api := newMockAPI()
	b := New(api, &mockHandler{})
	tracer := observability.NewDispatchTracer(nil)
	b.SetTracer(tracer)
	if b.tracer != tracer {
		t.Fatal("tracer was not set")
	}

	buttons := [][]Button{{{Text: "Approve", Data: "ok"}}}
	if err := b.SendWithButtons(context.Background(), OutboundMessage{ChatID: 1, Text: "choose"}, buttons); err != nil {
		t.Fatalf("SendWithButtons: %v", err)
	}
	if len(api.sent) != 1 || api.sent[0].Text != "choose" {
		t.Fatalf("button send did not delegate: %#v", api.sent)
	}

	errAPI := newMockAPI()
	errAPI.sendErr = errors.New("down")
	errBot := New(errAPI, &mockHandler{})
	if err := errBot.SendWithButtons(context.Background(), OutboundMessage{ChatID: 1}, buttons); err == nil || !strings.Contains(err.Error(), "api send with buttons: down") {
		t.Fatalf("expected wrapped send-with-buttons error, got %v", err)
	}
}

func TestPairingHandlerHandleCallback(t *testing.T) {
	t.Parallel()

	store := &mockPairingStore{authorizedIDs: map[int64]bool{42: true}}
	inner := &callbackRecordingHandler{}
	handler := NewPairingHandler(store, inner)
	if err := handler.HandleCallback(context.Background(), InboundCallback{ChatID: 42, Data: "ok"}); err != nil {
		t.Fatalf("authorized callback: %v", err)
	}
	if inner.callbackCalls != 1 {
		t.Fatalf("inner callback calls = %d", inner.callbackCalls)
	}

	unauthorized := NewPairingHandler(&mockPairingStore{authorizedIDs: map[int64]bool{}}, inner)
	if err := unauthorized.HandleCallback(context.Background(), InboundCallback{ChatID: 99}); err == nil || !strings.Contains(err.Error(), "unauthorized callback") {
		t.Fatalf("expected unauthorized callback error, got %v", err)
	}

	authErr := NewPairingHandler(&mockPairingStore{authErr: errors.New("db down")}, inner)
	if err := authErr.HandleCallback(context.Background(), InboundCallback{ChatID: 99}); err == nil || !strings.Contains(err.Error(), "check authorization") {
		t.Fatalf("expected authorization check error, got %v", err)
	}

	innerErr := &callbackRecordingHandler{callbackErr: errors.New("handler down")}
	delegateErr := NewPairingHandler(&mockPairingStore{authorizedIDs: map[int64]bool{99: true}}, innerErr)
	if err := delegateErr.HandleCallback(context.Background(), InboundCallback{ChatID: 99}); err == nil || !strings.Contains(err.Error(), "inner callback") {
		t.Fatalf("expected inner callback error, got %v", err)
	}
}

type callbackRecordingHandler struct {
	callbackCalls int
	callbackErr   error
}

func (h *callbackRecordingHandler) Handle(context.Context, string, InboundMessage) (string, error) {
	return "", nil
}

func (h *callbackRecordingHandler) HandleCallback(context.Context, InboundCallback) error {
	h.callbackCalls++
	return h.callbackErr
}
