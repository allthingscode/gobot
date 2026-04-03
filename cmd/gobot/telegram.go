package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/resilience"
	"github.com/allthingscode/gobot/internal/telegram"
	telego "github.com/mymmrac/telego"
)

type tgAPI struct {
	client    *telego.Bot
	breaker   *resilience.Breaker
	seenMsgs  sync.Map
	allowFrom map[int64]bool
	msgChan   chan bot.InboundMessage
	cbChan    chan bot.InboundCallback
}

func newTgAPI(token string, allowFrom []string, cfg *config.Config) (*tgAPI, error) {
	client, err := telego.NewBot(token)
	if err != nil {
		return nil, fmt.Errorf("telego: %w", err)
	}
	self, err := client.GetMe(context.Background())
	if err != nil {
		return nil, fmt.Errorf("telego GetMe: %w", err)
	}
	slog.Info("telegram: bot connected", "username", self.Username)

	af := make(map[int64]bool, len(allowFrom))
	for _, s := range allowFrom {
		if id, err := strconv.ParseInt(s, 10, 64); err == nil {
			af[id] = true
		}
	}

	maxFail, window, timeout := cfg.Breaker("telegram")
	breaker := resilience.New("telegram", maxFail, window, timeout)

	return &tgAPI{
		client:    client,
		breaker:   breaker,
		allowFrom: af,
		msgChan:   make(chan bot.InboundMessage, 100),
		cbChan:    make(chan bot.InboundCallback, 100),
	}, nil
}

const dedupTTL = 5 * time.Minute

// isDuplicate reports whether key was already seen within dedupTTL.
// key must be "chatID:messageID" to avoid false positives across chats.
// Stores key on first call; evicts expired entries on every call.
func (t *tgAPI) isDuplicate(key string) bool {
	now := time.Now()

	// Opportunistically evict expired entries.
	t.seenMsgs.Range(func(k, v any) bool {
		if now.Sub(v.(time.Time)) >= dedupTTL {
			t.seenMsgs.Delete(k)
		}
		return true
	})

	if v, ok := t.seenMsgs.Load(key); ok {
		if now.Sub(v.(time.Time)) < dedupTTL {
			return true
		}
	}
	t.seenMsgs.Store(key, now)
	return false
}

func (t *tgAPI) Updates(ctx context.Context, timeout int) (<-chan bot.InboundMessage, error) {
	if t.breaker.State() == "open" {
		return nil, resilience.ErrCircuitOpen
	}

	// Re-initialize channels to allow multiple Run attempts (F-054 fix).
	// Always initialize both to avoid nil-channel panics in startPoller.
	t.msgChan = make(chan bot.InboundMessage, 100)
	if t.cbChan == nil {
		t.cbChan = make(chan bot.InboundCallback, 100)
	}
	go t.startPoller(ctx)
	return t.msgChan, nil
}

func (t *tgAPI) Callbacks(ctx context.Context) (<-chan bot.InboundCallback, error) {
	// Re-initialize channels to allow multiple Run attempts (F-054 fix).
	if t.cbChan == nil {
		t.cbChan = make(chan bot.InboundCallback, 100)
	}
	return t.cbChan, nil
}

func (t *tgAPI) startPoller(ctx context.Context) {
	defer close(t.msgChan)
	defer close(t.cbChan)
	defer func() {
		if r := recover(); r != nil {
			slog.Error("PANIC IN STARTPOLLER", "err", r)
		}
	}()
	offset := 0
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		var updates []telego.Update
		err := t.breaker.Execute(func() error {
			var pollErr error
			updates, pollErr = t.client.GetUpdates(ctx, &telego.GetUpdatesParams{
				Offset:         offset,
				Timeout:        30,
				AllowedUpdates: []string{"message", "callback_query"},
			})
			return pollErr
		})
		if err != nil {
			if errors.Is(err, resilience.ErrCircuitOpen) {
				slog.Warn("telegram: circuit breaker is open, stopping poller session")
				return // Return error to trigger Bot.Run reconnection/backoff
			}
			slog.Error("telegram: GetUpdates failed", "err", err)
			return // Return to allow Bot.Run to handle retry delay
		}

		for _, update := range updates {
			if update.UpdateID >= offset {
				offset = update.UpdateID + 1
			}
			slog.Info("telegram: raw update received",
				"updateID", update.UpdateID,
				"hasMessage", update.Message != nil,
				"hasCallback", update.CallbackQuery != nil,
				"hasEditedMessage", update.EditedMessage != nil,
				"hasChannelPost", update.ChannelPost != nil,
			)

			// Handle Messages
			if update.Message != nil && update.Message.Text != "" {
				msgID := int64(update.Message.MessageID)
				dedupKey := fmt.Sprintf("%d:%d", update.Message.Chat.ID, msgID)
				if !t.isDuplicate(dedupKey) {
					if len(t.allowFrom) > 0 && !t.allowFrom[update.Message.Chat.ID] {
						slog.Warn("telegram: message from unlisted chat ID dropped", "chatID", update.Message.Chat.ID)
					} else {
						slog.Info("telegram: message received", "chatID", update.Message.Chat.ID, "text", update.Message.Text)
						var senderID int64
						if update.Message.From != nil {
							senderID = update.Message.From.ID
						}
						select {
						case t.msgChan <- bot.InboundMessage{
							ChatID:    update.Message.Chat.ID,
							MessageID: msgID,
							ThreadID:  int64(update.Message.MessageThreadID),
							SenderID:  senderID,
							Text:      update.Message.Text,
						}:
						case <-ctx.Done():
							return
						}
					}
				}
			}

			// Handle Callback Queries
			if update.CallbackQuery != nil {
				cb := update.CallbackQuery
				slog.Info("telegram: callback query received", "id", cb.ID, "data", cb.Data, "from", cb.From.ID)
				var chatID int64
				var msgID int64
				if cb.Message != nil {
					chatID = cb.Message.GetChat().ID
					msgID = int64(cb.Message.GetMessageID())
				}

				// Answer callback immediately to stop loading spinner
				_ = t.breaker.Execute(func() error {
					return t.client.AnswerCallbackQuery(ctx, &telego.AnswerCallbackQueryParams{
						CallbackQueryID: cb.ID,
					})
				})

				slog.Debug("telegram: forwarding callback to channel", "id", cb.ID, "reqID", cb.Data)
				select {
				case t.cbChan <- bot.InboundCallback{
					ChatID:     chatID,
					MessageID:  msgID,
					SenderID:   cb.From.ID,
					Data:       cb.Data,
					SessionKey: bot.SessionKey(chatID, 0, cb.From.ID),
				}:
					slog.Debug("telegram: callback sent to channel", "id", cb.ID)
				case <-ctx.Done():
					return
				}
			}
		}
	}
}

func (t *tgAPI) Typing(ctx context.Context, chatID, threadID int64) func() {
	stop := make(chan struct{})

	sendTyping := func() {
		params := &telego.SendChatActionParams{
			ChatID: telego.ChatID{ID: chatID},
			Action: telego.ChatActionTyping,
		}
		if threadID > 0 {
			params.MessageThreadID = int(threadID)
		}
		if err := t.breaker.Execute(func() error {
			return t.client.SendChatAction(ctx, params)
		}); err != nil {
			slog.Debug("telegram: typing action failed", "err", err)
		}
	}

	slog.Debug("telegram: sending initial typing action", "chat_id", chatID)
	sendTyping()

	go func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-stop:
				return
			case <-ticker.C:
				sendTyping()
			}
		}
	}()

	return func() { close(stop) }
}

func (t *tgAPI) Send(ctx context.Context, msg bot.OutboundMessage) error {
	params := &telego.SendMessageParams{
		ChatID:    telego.ChatID{ID: msg.ChatID},
		Text:      telegram.ToHTML(msg.Text),
		ParseMode: telego.ModeHTML,
	}
	if msg.ThreadID > 0 {
		params.MessageThreadID = int(msg.ThreadID)
	}
	if msg.ReplyToID > 0 {
		params.ReplyParameters = &telego.ReplyParameters{MessageID: int(msg.ReplyToID)}
	}
	err := t.breaker.Execute(func() error {
		_, err := t.client.SendMessage(ctx, params)
		return err
	})
	if err != nil && strings.Contains(err.Error(), "can't parse entities") {
		params.ParseMode = ""
		params.Text = msg.Text
		err = t.breaker.Execute(func() error {
			_, err := t.client.SendMessage(ctx, params)
			return err
		})
	}
	if err != nil {
		return fmt.Errorf("telego send: %w", err)
	}
	return nil
}

func (t *tgAPI) SendWithButtons(ctx context.Context, msg bot.OutboundMessage, buttons [][]bot.Button) error {
	rows := make([][]telego.InlineKeyboardButton, len(buttons))
	for i, row := range buttons {
		rows[i] = make([]telego.InlineKeyboardButton, len(row))
		for j, btn := range row {
			rows[i][j] = telego.InlineKeyboardButton{
				Text:         btn.Text,
				CallbackData: btn.Data,
			}
		}
	}

	params := &telego.SendMessageParams{
		ChatID:      telego.ChatID{ID: msg.ChatID},
		Text:        telegram.ToHTML(msg.Text),
		ParseMode:   telego.ModeHTML,
		ReplyMarkup: &telego.InlineKeyboardMarkup{InlineKeyboard: rows},
	}
	if msg.ThreadID > 0 {
		params.MessageThreadID = int(msg.ThreadID)
	}
	err := t.breaker.Execute(func() error {
		_, err := t.client.SendMessage(ctx, params)
		return err
	})
	if err != nil {
		return fmt.Errorf("telego SendWithButtons: %w", err)
	}
	return nil
}

func (t *tgAPI) Stop() {}
