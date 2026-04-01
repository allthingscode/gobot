package bot

import (
	"context"
	"fmt"
	"log/slog"
)

// PairingStorer is the subset of PairingStore methods needed by PairingHandler.
type PairingStorer interface {
	IsAuthorized(chatID int64) (bool, error)
	GetOrCreateCode(chatID int64) (string, error)
}

// PairingHandler wraps an inner Handler and gates access via PairingStore.
type PairingHandler struct {
	store PairingStorer
	inner Handler
}

// NewPairingHandler returns a PairingHandler that delegates to inner for authorized users.
func NewPairingHandler(store PairingStorer, inner Handler) *PairingHandler {
	return &PairingHandler{store: store, inner: inner}
}

func (h *PairingHandler) Handle(ctx context.Context, sessionKey string, msg InboundMessage) (string, error) {
	authorized, err := h.store.IsAuthorized(msg.ChatID)
	if err != nil {
		slog.Warn("pairing: auth check failed", "chat_id", msg.ChatID, "err", err)
		return "", err
	}

	if authorized {
		return h.inner.Handle(ctx, sessionKey, msg)
	}

	code, err := h.store.GetOrCreateCode(msg.ChatID)
	if err != nil {
		slog.Warn("pairing: get or create code failed", "chat_id", msg.ChatID, "err", err)
		return "", err
	}

	return fmt.Sprintf(
		"You are not authorized to use this bot.\n\nYour pairing code is: %s\n\nGive this code to the operator to request access.",
		code,
	), nil
}

// HandleCallback checks authorization and delegates to the inner handler for authorized users.
func (h *PairingHandler) HandleCallback(ctx context.Context, cb InboundCallback) error {
	authorized, err := h.store.IsAuthorized(cb.ChatID)
	if err != nil {
		return err
	}
	if !authorized {
		return fmt.Errorf("unauthorized callback from %d", cb.ChatID)
	}
	return h.inner.HandleCallback(ctx, cb)
}
