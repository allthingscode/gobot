package bot

import (
	"context"
	"errors"
	"strings"
	"testing"
)

type mockPairingStore struct {
	authorizedIDs map[int64]bool
	codes         map[int64]string
	codeErr       error
	authErr       error
}

func (m *mockPairingStore) IsAuthorized(chatID int64) (bool, error) {
	if m.authErr != nil {
		return false, m.authErr
	}
	return m.authorizedIDs[chatID], nil
}

func (m *mockPairingStore) GetOrCreateCode(chatID int64) (string, error) {
	if m.codeErr != nil {
		return "", m.codeErr
	}
	if code, ok := m.codes[chatID]; ok {
		return code, nil
	}
	return "123456", nil
}

type mockInnerHandler struct {
	reply string
	err   error
}

func (m *mockInnerHandler) Handle(_ context.Context, _ string, _ InboundMessage) (string, error) {
	return m.reply, m.err
}

func (m *mockInnerHandler) HandleCallback(_ context.Context, _ InboundCallback) error {
	return nil
}

func TestPairingHandler_AuthorizedUser_DelegatesToInner(t *testing.T) {
	t.Parallel()
	store := &mockPairingStore{
		authorizedIDs: map[int64]bool{1: true},
	}
	inner := &mockInnerHandler{reply: "hello from inner"}
	handler := NewPairingHandler(store, inner)

	msg := InboundMessage{ChatID: 1, Text: "hi"}
	reply, err := handler.Handle(context.Background(), "key", msg)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if reply != "hello from inner" {
		t.Errorf("expected inner reply, got %q", reply)
	}
}

func TestPairingHandler_UnauthorizedUser_ReturnsPairingCode(t *testing.T) {
	t.Parallel()
	store := &mockPairingStore{
		authorizedIDs: map[int64]bool{},
	}
	inner := &mockInnerHandler{reply: "should not reach"}
	handler := NewPairingHandler(store, inner)

	msg := InboundMessage{ChatID: 2, Text: "hi"}
	reply, err := handler.Handle(context.Background(), "key", msg)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(reply, "123456") {
		t.Errorf("expected reply to contain pairing code %q, got %q", "123456", reply)
	}
}

func TestPairingHandler_IsAuthorized_Error_ReturnsError(t *testing.T) {
	t.Parallel()
	authErr := errors.New("db unavailable")
	store := &mockPairingStore{
		authErr: authErr,
	}
	inner := &mockInnerHandler{}
	handler := NewPairingHandler(store, inner)

	msg := InboundMessage{ChatID: 3, Text: "hi"}
	_, err := handler.Handle(context.Background(), "key", msg)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !errors.Is(err, authErr) {
		t.Errorf("expected authErr, got %v", err)
	}
}

func TestPairingHandler_GetOrCreateCode_Error_ReturnsError(t *testing.T) {
	t.Parallel()
	codeErr := errors.New("code generation failed")
	store := &mockPairingStore{
		authorizedIDs: map[int64]bool{},
		codeErr:       codeErr,
	}
	inner := &mockInnerHandler{}
	handler := NewPairingHandler(store, inner)

	msg := InboundMessage{ChatID: 4, Text: "hi"}
	_, err := handler.Handle(context.Background(), "key", msg)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !errors.Is(err, codeErr) {
		t.Errorf("expected codeErr, got %v", err)
	}
}
