// Package bot provides a Telegram polling bot runtime with resilience features.
// It is the Go equivalent of TelegramPatch in strategery/patches/telegram.py.
// This package contains pure logic and interfaces only — no Telegram SDK dependency.
// The concrete go-telegram-bot-api adapter lives in cmd/gobot/.
package bot

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"strings"
	"time"
)

// InboundMessage is a normalized message received from Telegram.
type InboundMessage struct {
	ChatID    int64
	MessageID int64
	ThreadID  int64 // 0 for non-topic (DM/group) chats
	SenderID  int64 // Telegram user ID of the sender (from Message.From.ID)
	Text      string
}

// Button represents an inline keyboard button.
type Button struct {
	Text string
	Data string
}

// InboundCallback is a normalized callback query from an inline button.
type InboundCallback struct {
	ChatID     int64
	MessageID  int64
	SenderID   int64
	Data       string
	SessionKey string
}

// OutboundMessage is a message to send via Telegram.
type OutboundMessage struct {
	ChatID    int64
	ThreadID  int64 // 0 = no topic thread
	ReplyToID int64 // 0 = no reply targeting
	Text      string
}

// API abstracts the Telegram bot client for testability.
// Production implementation (using go-telegram-bot-api) lives in cmd/gobot/.
// Implementations must be safe for concurrent use.
type API interface {
	// Updates returns a channel of inbound messages. The channel is closed
	// when Stop() is called or ctx is cancelled.
	Updates(ctx context.Context, timeout int) (<-chan InboundMessage, error)
	// Callbacks returns a channel of inbound callback queries.
	Callbacks(ctx context.Context) (<-chan InboundCallback, error)
	// Send delivers an outbound message.
	Send(ctx context.Context, msg OutboundMessage) error
	// SendWithButtons delivers a message with inline keyboard buttons.
	SendWithButtons(ctx context.Context, msg OutboundMessage, buttons [][]Button) error
	// Typing starts a periodic typing indicator. Returns a stop function.
	Typing(ctx context.Context, chatID, threadID int64) func()
	// Stop signals the API to stop delivering updates.
	Stop()
}

// Handler processes an inbound message and returns a reply text.
// Returning an empty string means no reply should be sent.
// Implementations must be safe for concurrent use.
type Handler interface {
	Handle(ctx context.Context, sessionKey string, msg InboundMessage) (string, error)
	HandleCallback(ctx context.Context, cb InboundCallback) error
}

// Bot is the Telegram polling runtime.
type Bot struct {
	api     API
	handler Handler
}

// New creates a Bot backed by the given API and Handler.
func New(api API, handler Handler) *Bot {
	return &Bot{api: api, handler: handler}
}

// SessionKey returns the routing key for a message.
//
// Format:
//   - DM (chatID > 0):           "telegram:<chatID>"
//   - DM topic (chatID > 0):     "telegram:<chatID>:<threadID>"
//   - Group (chatID < 0):        "telegram:<chatID>:<senderID>"
//
// Group chats use a per-user key so each sender has an isolated context.
// Cron sessions use the "cron:" prefix and are unaffected.
//
// Mirrors DetectThreadMetadata in internal/telegram and session_key_override
// in strategery/patches/telegram.py.
func SessionKey(chatID, threadID, senderID int64) string {
	if chatID < 0 {
		// Group or supergroup: isolate per sender.
		if senderID > 0 {
			return fmt.Sprintf("telegram:%d:%d", chatID, senderID)
		}
		return fmt.Sprintf("telegram:%d", chatID)
	}
	// DM: factor in topic thread if present.
	if threadID > 0 {
		return fmt.Sprintf("telegram:%d:%d", chatID, threadID)
	}
	return fmt.Sprintf("telegram:%d", chatID)
}

// IsTransientError returns true if err represents a recoverable network
// condition that should trigger a retry rather than a crash.
// Mirrors suppress_patterns in _strategic_on_error (patches/telegram.py).
func IsTransientError(err error) bool {
	if err == nil {
		return false
	}
	if err == io.EOF || err == context.DeadlineExceeded {
		return true
	}
	msg := strings.ToLower(err.Error())
	for _, p := range []string{
		"readerror", "remoteprotocolerror", "timed out",
		"connecterror", "connection reset by peer", "connection reset", "network",
	} {
		if strings.Contains(msg, p) {
			return true
		}
	}
	return false
}

// Run starts the polling loop. Blocks until ctx is cancelled.
//
// Any error from API.Updates triggers exponential backoff:
// initial 5s, doubles each retry, capped at 60s, resets to 5s on success.
// Mirrors strategic_telegram_polling_loop in patches/telegram.py.
func (b *Bot) Run(ctx context.Context) error {
	const initialDelay = 5 * time.Second
	const maxDelay = 60 * time.Second
	retryDelay := initialDelay

	callbacks, err := b.api.Callbacks(ctx)
	if err != nil {
		return fmt.Errorf("bot: Callbacks failed: %w", err)
	}

	// Handle callbacks in a dedicated goroutine so they never block on updates.
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case cb, ok := <-callbacks:
				if !ok {
					return
				}
				go func() {
					if err := b.handler.HandleCallback(ctx, cb); err != nil {
						slog.Error("bot: HandleCallback failed", "err", err)
					}
				}()
			}
		}
	}()

	for {
		updates, err := b.api.Updates(ctx, 30)
		if err != nil {
			slog.Error("bot: Updates failed", "err", err, "retry_in", retryDelay)
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(retryDelay):
			}
			retryDelay *= 2
			if retryDelay > maxDelay {
				retryDelay = maxDelay
			}
			continue
		}
		retryDelay = initialDelay // reset on successful connect

		slog.Debug("bot: update stream connected, draining messages")
	drain:
		for {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case msg, ok := <-updates:
				if !ok {
					break drain // channel closed — reconnect
				}
				go b.dispatch(ctx, msg)
			}
		}
	}
}

// dispatch processes a single inbound message and sends a reply if non-empty.
func (b *Bot) dispatch(ctx context.Context, msg InboundMessage) {
	sessionKey := SessionKey(msg.ChatID, msg.ThreadID, msg.SenderID)
	slog.Info("bot: message received", "session", sessionKey, "text", msg.Text)

	// Start typing indicator
	stopTyping := b.api.Typing(ctx, msg.ChatID, msg.ThreadID)
	defer stopTyping()

	reply, err := b.handler.Handle(ctx, sessionKey, msg)
	if err != nil {
		slog.Error("bot: handler error", "session", sessionKey, "err", err)
		return
	}
	if reply == "" {
		return
	}
	out := OutboundMessage{
		ChatID:   msg.ChatID,
		ThreadID: msg.ThreadID,
		Text:     reply,
	}
	if err := b.api.Send(ctx, out); err != nil {
		slog.Error("bot: send error", "session", sessionKey, "err", err)
	} else {
		slog.Info("bot: message sent", "session", sessionKey)
	}
}

// Send delivers a message via the underlying API.
func (b *Bot) Send(ctx context.Context, msg OutboundMessage) error {
	return b.api.Send(ctx, msg)
}

// SendWithButtons delivers a message with buttons via the underlying API.
func (b *Bot) SendWithButtons(ctx context.Context, msg OutboundMessage, buttons [][]Button) error {
	return b.api.SendWithButtons(ctx, msg, buttons)
}
