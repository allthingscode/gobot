// Package bot provides a Telegram polling bot runtime with resilience features.
// It is the Go equivalent of TelegramPatch in strategery/patches/telegram.py.
// This package contains pure logic and interfaces only — no Telegram SDK dependency.
// The concrete telego adapter lives in cmd/gobot/.
package bot

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"strings"
	"time"

	"golang.org/x/sync/errgroup"
	"github.com/allthingscode/gobot/internal/observability"
)

// InboundMessage is a normalized message received from Telegram.
type InboundMessage struct {
	ChatID    int64
	MessageID int64
	ThreadID  int64 // 0 for non-topic (DM/group) chats
	SenderID  int64 // Telegram user ID of the sender (from Message.From.ID)
	Text      string
}

// Validate ensures required fields are present and sensible.
// Mirrors validation constraints in C-042 specification.
func (m InboundMessage) Validate() error {
	if m.ChatID == 0 {
		return errors.New("missing ChatID")
	}
	if m.SenderID == 0 {
		return errors.New("missing SenderID")
	}
	if m.ThreadID < 0 {
		return errors.New("negative ThreadID")
	}
	return nil
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
// Production implementation (using telego) lives in cmd/gobot/.
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

// UserID returns a unique identifier for the user to support workspace isolation (F-073).
// For DMs, this is the chatID. For groups, it is the senderID.
func UserID(chatID, senderID int64) string {
	if chatID > 0 {
		return fmt.Sprintf("%d", chatID)
	}
	return fmt.Sprintf("%d", senderID)
}

// Bot is the Telegram polling runtime.
type Bot struct {
	api     API
	handler Handler
	tracer  *observability.DispatchTracer
}

// New creates a Bot backed by the given API and Handler.
func New(api API, handler Handler) *Bot {
	return &Bot{api: api, handler: handler}
}

// SetTracer configures the observability tracer for the bot.
func (b *Bot) SetTracer(t *observability.DispatchTracer) {
	b.tracer = t
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
	if errors.Is(err, io.EOF) || errors.Is(err, context.DeadlineExceeded) {
		return true
	}
	msg := strings.ToLower(err.Error())
	for _, p := range []string{
		"readerror", "remoteprotocolerror", "timed out",
		"connecterror", "connection reset by peer", "connection reset", "network",
		"closed connection", "server closed",
	} {
		if strings.Contains(msg, p) {
			return true
		}
	}
	return false
}

// Run starts the polling loop. Blocks until ctx is cancelled.
// It coordinates parallel execution of callback and update polling loops.
// Mirrors strategic_telegram_polling_loop in patches/telegram.py.
func (b *Bot) Run(ctx context.Context) error {
	if b.api == nil {
		slog.Info("bot: no Telegram API configured, skipping polling loop")
		<-ctx.Done()
		return ctx.Err()
	}

	g, ctx := errgroup.WithContext(ctx)

	g.Go(func() error {
		return b.runCallbackLoop(ctx)
	})

	g.Go(func() error {
		return b.runUpdateLoop(ctx)
	})

	return g.Wait()
}

// runCallbackLoop manages the lifecycle of the callback polling channel.
// Any error from API.Callbacks triggers exponential backoff:
// initial 5s, doubles each retry, capped at 60s, resets to 5s on success.
func (b *Bot) runCallbackLoop(ctx context.Context) error {
	const initialDelay = 5 * time.Second
	const maxDelay = 60 * time.Second
	retryDelay := initialDelay

	for {
		callbacks, err := b.api.Callbacks(ctx)
		if err != nil {
			if e := b.waitRetry(ctx, "Callbacks", err, &retryDelay, maxDelay); e != nil {
				return e
			}
			continue
		}
		retryDelay = initialDelay

		if err := b.drainCallbacks(ctx, callbacks); err != nil {
			return err
		}
	}
}

func (b *Bot) drainCallbacks(ctx context.Context, callbacks <-chan InboundCallback) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case cb, ok := <-callbacks:
			if !ok {
				return nil // reconnect
			}
			slog.Info("bot: callback received from API channel", "chatID", cb.ChatID, "session", cb.SessionKey)
			go b.dispatchCallback(ctx, cb)
		}
	}
}

func (b *Bot) dispatchCallback(ctx context.Context, cb InboundCallback) {
	if err := b.handler.HandleCallback(ctx, cb); err != nil {
		if errors.Is(err, context.Canceled) {
			slog.Warn("bot: HandleCallback canceled by context", "chatID", cb.ChatID)
		} else {
			slog.Error("bot: HandleCallback failed", "err", err)
		}
	}
}

func (b *Bot) runUpdateLoop(ctx context.Context) error {
	const initialDelay = 5 * time.Second
	const maxDelay = 60 * time.Second
	retryDelay := initialDelay

	for {
		updates, err := b.api.Updates(ctx, 30)
		if err != nil {
			if e := b.waitRetry(ctx, "Updates", err, &retryDelay, maxDelay); e != nil {
				return e
			}
			continue
		}
		retryDelay = initialDelay

		slog.Debug("bot: update stream connected, draining messages")
		if err := b.drainUpdates(ctx, updates); err != nil {
			return err
		}
	}
}

func (b *Bot) drainUpdates(ctx context.Context, updates <-chan InboundMessage) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case msg, ok := <-updates:
			if !ok {
				return nil // reconnect
			}
			go b.dispatch(ctx, msg)
		}
	}
}

func (b *Bot) waitRetry(ctx context.Context, op string, err error, delay *time.Duration, maxDelay time.Duration) error {
	slog.Error("bot: "+op+" failed", "err", err, "retry_in", *delay)
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(*delay):
	}
	*delay *= 2
	if *delay > maxDelay {
		*delay = maxDelay
	}
	return nil
}

// dispatch processes a single inbound message and sends a reply if non-empty.
func (b *Bot) dispatch(ctx context.Context, msg InboundMessage) {
	if err := msg.Validate(); err != nil {
		slog.Warn("bot: invalid inbound message dropped", "err", err)
		return
	}

	sessionKey := SessionKey(msg.ChatID, msg.ThreadID, msg.SenderID)
	slog.Info("bot: message received", "session", sessionKey, "text", msg.Text)

	// Start typing indicator
	stopTyping := b.api.Typing(ctx, msg.ChatID, msg.ThreadID)
	defer stopTyping()

	if b.tracer != nil {
		_ = b.tracer.TraceBotDispatch(ctx, sessionKey, func(ctx context.Context) error {
			return b.handleAndSend(ctx, sessionKey, msg)
		})
		return
	}

	if err := b.handleAndSend(ctx, sessionKey, msg); err != nil {
		slog.Error("bot: handleAndSend failed", "session", sessionKey, "err", err)
	}
}

// handleAndSend is the untraced implementation of dispatch.
func (b *Bot) handleAndSend(ctx context.Context, sessionKey string, msg InboundMessage) error {
	reply, err := b.handler.Handle(ctx, sessionKey, msg)
	if err != nil {
		return err
	}
	if reply == "" {
		return nil
	}
	out := OutboundMessage{
		ChatID:   msg.ChatID,
		ThreadID: msg.ThreadID,
		Text:     reply,
	}
	if err := b.api.Send(ctx, out); err != nil {
		return fmt.Errorf("send error: %w", err)
	}
	slog.Info("bot: message sent", "session", sessionKey)
	return nil
}

// Send delivers a message via the underlying API.
func (b *Bot) Send(ctx context.Context, msg OutboundMessage) error {
	return b.api.Send(ctx, msg)
}

// SendWithButtons delivers a message with buttons via the underlying API.
func (b *Bot) SendWithButtons(ctx context.Context, msg OutboundMessage, buttons [][]Button) error {
	return b.api.SendWithButtons(ctx, msg, buttons)
}
