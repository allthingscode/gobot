package app

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"sync/atomic"
	"time"

	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/reminder"
)

type reminderCapabilityKey struct{}

// This capability is minted only at the Telegram runtime entry, never by the
// shared DispatchHandler (which also accepts gateway traffic) or session parsing.
type reminderCapability struct {
	owner   reminder.Owner
	topicID int64
	session string
	userID  string
	active  atomic.Bool
}

type reminderAuthorization struct {
	cfg *config.Config
	db  *sql.DB
}

func (a reminderAuthorization) allowed(ctx context.Context, owner reminder.Owner) (bool, error) {
	if err := owner.Validate(); err != nil {
		return false, fmt.Errorf("reminder authorization identity: %w", err)
	}
	if a.cfg == nil || !a.cfg.Channels.Telegram.Enabled || a.db == nil {
		return false, errors.New("reminder: Telegram authorization unavailable")
	}
	listed := false
	for _, raw := range a.cfg.TelegramAllowedFrom() {
		chatID, err := config.ParseTelegramChatID(raw)
		if err != nil {
			return false, errors.New("reminder: invalid Telegram whitelist")
		}
		listed = listed || chatID == owner.ChatID
	}
	if !listed {
		return false, nil
	}
	// Use the shared pairing table with the send/request deadline. The existing
	// PairingStore method uses Background, which cannot bound a blocked lookup.
	var paired bool
	if err := a.db.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM authorized_users WHERE chat_id=?)`, owner.ChatID).Scan(&paired); err != nil {
		return false, errors.New("reminder: pairing lookup failed")
	}
	return paired, nil
}

type reminderTelegramHandler struct {
	bot.Handler
	auth reminderAuthorization
}

func (h reminderTelegramHandler) Handle(ctx context.Context, session string, msg bot.InboundMessage) (string, error) {
	if err := msg.Validate(); err != nil {
		return "", fmt.Errorf("reminder inbound metadata: %w", err)
	}
	if msg.SenderID <= 0 || session != bot.SessionKey(msg.ChatID, msg.ThreadID, msg.SenderID) {
		return "", errors.New("reminder: malformed Telegram identity")
	}
	lookupCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	allowed, err := h.auth.allowed(lookupCtx, reminder.Owner{ChatID: msg.ChatID, SenderID: msg.SenderID})
	cancel()
	if err != nil {
		return "", fmt.Errorf("reminder inbound authorization: %w", err)
	}
	if !allowed {
		// Preserve the existing pairing response, but never grant a capability.
		return h.dispatch(withoutReminderCapability(ctx), session, msg)
	}
	capability := &reminderCapability{owner: reminder.Owner{ChatID: msg.ChatID, SenderID: msg.SenderID}, topicID: msg.ThreadID, session: session, userID: bot.UserID(msg.ChatID, msg.SenderID)}
	capability.active.Store(true)
	defer capability.active.Store(false)
	return h.dispatch(context.WithValue(ctx, reminderCapabilityKey{}, capability), session, msg)
}

func (h reminderTelegramHandler) dispatch(ctx context.Context, session string, msg bot.InboundMessage) (string, error) {
	result, err := h.Handler.Handle(ctx, session, msg)
	if err != nil {
		return "", fmt.Errorf("reminder Telegram dispatch: %w", err)
	}
	return result, nil
}

func withoutReminderCapability(ctx context.Context) context.Context {
	return context.WithValue(ctx, reminderCapabilityKey{}, (*reminderCapability)(nil))
}

func reminderIdentity(ctx context.Context, session, userID string) (*reminderCapability, error) {
	c, ok := ctx.Value(reminderCapabilityKey{}).(*reminderCapability)
	if !ok || c == nil || !c.active.Load() || c.session != session || c.userID != userID || !bot.IsTelegramSession(session) {
		return nil, errors.New("reminder: authenticated inbound Telegram request required")
	}
	return c, nil
}
