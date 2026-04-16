package app

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

type TgAPI struct {
	client    *telego.Bot
	breaker   *resilience.Breaker
	seenMsgs  sync.Map
	allowFrom map[int64]bool
	msgChan   chan bot.InboundMessage
	cbChan    chan bot.InboundCallback
}

func NewTgAPI(token string, allowFrom []string, cfg *config.Config) (*TgAPI, error) {
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

	return &TgAPI{
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
func (api *TgAPI) isDuplicate(key string) bool {
	now := time.Now()

	// Opportunistically evict expired entries.
	api.seenMsgs.Range(func(k, v any) bool {
		if now.Sub(v.(time.Time)) >= dedupTTL {
			api.seenMsgs.Delete(k)
		}
		return true
	})

	if v, ok := api.seenMsgs.Load(key); ok {
		if now.Sub(v.(time.Time)) < dedupTTL {
			return true
		}
	}
	api.seenMsgs.Store(key, now)
	return false
}

func (api *TgAPI) Updates(ctx context.Context, _ int) (<-chan bot.InboundMessage, error) {
	if api.breaker.State() == "open" {
		return nil, resilience.ErrCircuitOpen
	}

	// Re-initialize channels to allow multiple Run attempts (F-054 fix).
	// Always reinit both — cbChan may be closed (not nil) from a prior poller
	// session, and writing to a closed channel panics.
	api.msgChan = make(chan bot.InboundMessage, 100)
	api.cbChan = make(chan bot.InboundCallback, 100)
	go api.startPoller(ctx)
	return api.msgChan, nil
}

func (api *TgAPI) Callbacks(ctx context.Context) (<-chan bot.InboundCallback, error) {
	// Re-initialize channels to allow multiple Run attempts (F-054 fix).
	if api.cbChan == nil {
		api.cbChan = make(chan bot.InboundCallback, 100)
	}
	return api.cbChan, nil
}

func (api *TgAPI) startPoller(ctx context.Context) {
	defer close(api.msgChan)
	defer close(api.cbChan)
	defer api.recoverFromPollerPanic()

	offset := 0
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		updates, err := api.fetchUpdates(ctx, offset)
		if err != nil {
			// Brief pause before closing channels so the reconnect loop
			// in Bot.Run doesn't spin immediately on transient failures.
			select {
			case <-ctx.Done():
			case <-time.After(2 * time.Second):
			}
			return
		}

		for _, update := range updates {
			if update.UpdateID >= offset {
				offset = update.UpdateID + 1
			}
			api.handleUpdate(ctx, update)
		}
	}
}

func (api *TgAPI) recoverFromPollerPanic() {
	if r := recover(); r != nil {
		slog.Error("PANIC IN STARTPOLLER", "err", r)
	}
}

func (api *TgAPI) fetchUpdates(ctx context.Context, offset int) ([]telego.Update, error) {
	var updates []telego.Update
	err := api.breaker.Execute(func() error {
		var pollErr error
		updates, pollErr = api.client.GetUpdates(ctx, &telego.GetUpdatesParams{
			Offset:         offset,
			Timeout:        30,
			AllowedUpdates: []string{"message", "callback_query"},
		})
		return pollErr
	})

	if err != nil {
		switch {
		case errors.Is(err, resilience.ErrCircuitOpen):
			slog.Warn("telegram: circuit breaker is open, stopping poller session")
		case bot.IsTransientError(err):
			slog.Warn("telegram: GetUpdates transient error", "err", err)
		default:
			slog.Error("telegram: GetUpdates failed", "err", err)
		}
		return nil, err
	}
	return updates, nil
}

func (api *TgAPI) handleUpdate(ctx context.Context, update telego.Update) {
	slog.Info("telegram: raw update received",
		"updateID", update.UpdateID,
		"hasMessage", update.Message != nil,
		"hasCallback", update.CallbackQuery != nil,
	)

	if update.Message != nil && update.Message.Text != "" {
		api.handleMessage(ctx, update.Message)
	}

	if update.CallbackQuery != nil {
		api.handleCallbackQuery(ctx, update.CallbackQuery)
	}
}

func (api *TgAPI) handleMessage(ctx context.Context, m *telego.Message) {
	msgID := int64(m.MessageID)
	dedupKey := fmt.Sprintf("%d:%d", m.Chat.ID, msgID)
	if api.isDuplicate(dedupKey) {
		return
	}

	if len(api.allowFrom) > 0 && !api.allowFrom[m.Chat.ID] {
		slog.Warn("telegram: message from unlisted chat ID dropped", "chatID", m.Chat.ID)
		return
	}

	slog.Info("telegram: message received", "chatID", m.Chat.ID, "text", m.Text)
	var senderID int64
	if m.From != nil {
		senderID = m.From.ID
	}

	select {
	case api.msgChan <- bot.InboundMessage{
		ChatID:    m.Chat.ID,
		MessageID: msgID,
		ThreadID:  int64(m.MessageThreadID),
		SenderID:  senderID,
		Text:      m.Text,
	}:
	case <-ctx.Done():
	}
}

func (api *TgAPI) handleCallbackQuery(ctx context.Context, cb *telego.CallbackQuery) {
	slog.Info("telegram: callback query received", "id", cb.ID, "data", cb.Data, "from", cb.From.ID)
	var chatID int64
	var msgID int64
	if cb.Message != nil {
		chatID = cb.Message.GetChat().ID
		msgID = int64(cb.Message.GetMessageID())
	}

	// Answer callback immediately to stop loading spinner
	_ = api.breaker.Execute(func() error {
		return api.client.AnswerCallbackQuery(ctx, &telego.AnswerCallbackQueryParams{
			CallbackQueryID: cb.ID,
		})
	})

	slog.Debug("telegram: forwarding callback to channel", "id", cb.ID, "reqID", cb.Data)
	select {
	case api.cbChan <- bot.InboundCallback{
		ChatID:     chatID,
		MessageID:  msgID,
		SenderID:   cb.From.ID,
		Data:       cb.Data,
		SessionKey: bot.SessionKey(chatID, 0, cb.From.ID),
	}:
		slog.Debug("telegram: callback sent to channel", "id", cb.ID)
	case <-ctx.Done():
	}
}

func (api *TgAPI) Typing(ctx context.Context, chatID, threadID int64) func() {
	stop := make(chan struct{})

	sendTyping := func() {
		params := &telego.SendChatActionParams{
			ChatID: telego.ChatID{ID: chatID},
			Action: telego.ChatActionTyping,
		}
		if threadID > 0 {
			params.MessageThreadID = int(threadID)
		}
		if err := api.breaker.Execute(func() error {
			return api.client.SendChatAction(ctx, params)
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

func (api *TgAPI) Send(ctx context.Context, msg bot.OutboundMessage) error {
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
	err := api.breaker.Execute(func() error {
		_, err := api.client.SendMessage(ctx, params)
		return err
	})
	if err != nil && strings.Contains(err.Error(), "can't parse entities") {
		params.ParseMode = ""
		params.Text = msg.Text
		err = api.breaker.Execute(func() error {
			_, err := api.client.SendMessage(ctx, params)
			return err
		})
	}
	if err != nil {
		return fmt.Errorf("telego send: %w", err)
	}
	return nil
}

func (api *TgAPI) SendWithButtons(ctx context.Context, msg bot.OutboundMessage, buttons [][]bot.Button) error {
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
	err := api.breaker.Execute(func() error {
		_, err := api.client.SendMessage(ctx, params)
		return err
	})
	if err != nil {
		return fmt.Errorf("telego SendWithButtons: %w", err)
	}
	return nil
}

func (api *TgAPI) Stop() {}
