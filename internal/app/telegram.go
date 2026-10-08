package app

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"time"

	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/resilience"
	"github.com/allthingscode/gobot/internal/telegram"
	telego "github.com/mymmrac/telego"
)

// TgAPI implements bot.API using the telego library.
type TgAPI struct {
	// Legacy direct-handler fixtures; polling never publishes or sends through these fields.
	msgChan      chan bot.InboundMessage
	cbChan       chan bot.InboundCallback
	client       *telego.Bot
	breaker      *resilience.Breaker
	seenMsgs     sync.Map
	allowFrom    map[int64]bool
	lifecycle    sync.Mutex
	generation   *pollingGeneration
	nextUpdateID int
	username     string
}

// NewTgAPI initializes a new Telegram API adapter using the telego library.
func NewTgAPI(token string, allowFrom []string, cfg *config.Config) (*TgAPI, error) {
	af := make(map[int64]bool, len(allowFrom))
	for i, raw := range allowFrom {
		id, err := config.ParseTelegramChatID(raw)
		if err != nil {
			return nil, fmt.Errorf("telegram whitelist allowFrom[%d]: %w", i, err)
		}
		af[id] = true
	}
	if len(af) == 0 {
		return nil, errors.New("telegram whitelist channels.telegram.allowFrom: at least one nonzero signed decimal chat ID is required")
	}

	client, err := telego.NewBot(token, telego.WithDiscardLogger())
	if err != nil {
		return nil, fmt.Errorf("telego: %w", err)
	}
	self, err := client.GetMe(context.Background())
	if err != nil {
		return nil, fmt.Errorf("telego GetMe: %w", err)
	}
	slog.Info("telegram: bot connected", "username", self.Username)

	maxFail, window, timeout := cfg.Breaker("telegram")
	breaker := resilience.New("telegram", maxFail, window, timeout)

	return &TgAPI{
		client:    client,
		breaker:   breaker,
		allowFrom: af,
		username:  self.Username,
	}, nil
}

// Username returns the bot's Telegram username.
func (api *TgAPI) Username() string {
	return api.username
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

// pollingGeneration owns both subscriptions until its worker terminates.
type pollingGeneration struct {
	msgChan chan bot.InboundMessage
	cbChan  chan bot.InboundCallback
	ctx     context.Context
	cancel  context.CancelFunc
	start   chan struct{}
	done    chan struct{}
	started bool
	closed  bool
}

// acquire waits outside the lifecycle lock while a cancelled worker finishes.
func (api *TgAPI) acquire(ctx context.Context, start bool) (*pollingGeneration, error) {
	for {
		if err := ctx.Err(); err != nil {
			return nil, fmt.Errorf("telegram acquire: %w", err)
		}
		g, waiting, err := api.acquireGeneration(ctx, start)
		if err != nil {
			return nil, err
		}
		if !waiting {
			return g, nil
		}
		select {
		case <-g.done:
		case <-ctx.Done():
			return nil, fmt.Errorf("telegram acquire: %w", ctx.Err())
		}
	}
}

func (api *TgAPI) acquireGeneration(ctx context.Context, start bool) (*pollingGeneration, bool, error) {
	api.lifecycle.Lock()
	defer api.lifecycle.Unlock()
	g := api.generation
	if g != nil && !g.closed && g.ctx.Err() != nil {
		return g, true, nil
	}
	if start && api.breaker.State() == "open" {
		return nil, false, resilience.ErrCircuitOpen
	}
	if g == nil || g.closed {
		// The generation worker cancels its context on every exit; Stop also cancels it.
		owner, cancel := context.WithCancel(ctx) //nolint:gosec // cancellation ownership transfers to runGeneration.
		g = &pollingGeneration{msgChan: make(chan bot.InboundMessage, 100), cbChan: make(chan bot.InboundCallback, 100), ctx: owner, cancel: cancel, start: make(chan struct{}), done: make(chan struct{})}
		api.generation = g
		go api.runGeneration(g)
	}
	if start && !g.started {
		g.started = true
		close(g.start)
	}
	return g, false, nil
}

// Updates starts at most one poller for the current paired subscriptions.
func (api *TgAPI) Updates(ctx context.Context, _ int) (<-chan bot.InboundMessage, error) {
	g, err := api.acquire(ctx, true)
	if err != nil {
		return nil, err
	}
	return g.msgChan, nil
}

// Callbacks reserves or joins the same generation as Updates, in either order.
func (api *TgAPI) Callbacks(ctx context.Context) (<-chan bot.InboundCallback, error) {
	g, err := api.acquire(ctx, false)
	if err != nil {
		return nil, err
	}
	return g.cbChan, nil
}

func (api *TgAPI) runGeneration(g *pollingGeneration) {
	defer func() {
		g.cancel()
		api.lifecycle.Lock()
		defer api.lifecycle.Unlock()
		g.closed = true
		close(g.msgChan)
		close(g.cbChan)
		close(g.done)
	}()
	defer RecoverWithStack("telegram-poller")
	select {
	case <-g.ctx.Done():
		return
	case <-g.start:
	}
	api.startPoller(g)
}

func (api *TgAPI) startPoller(g *pollingGeneration) {
	for g.ctx.Err() == nil {
		updates, err := api.fetchUpdates(g.ctx, api.nextUpdateID)
		if err != nil {
			return
		}
		for _, update := range updates {
			if update.UpdateID < api.nextUpdateID {
				continue
			}
			api.nextUpdateID = update.UpdateID + 1
			api.handleGenerationUpdate(g.ctx, g, update)
		}
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
		if pollErr != nil {
			return fmt.Errorf("get updates: %w", pollErr)
		}
		return nil
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
		return nil, fmt.Errorf("breaker execute: %w", err)
	}
	return updates, nil
}

func (api *TgAPI) handleUpdate(ctx context.Context, update telego.Update) {
	api.handleGenerationUpdate(ctx, &pollingGeneration{msgChan: api.msgChan, cbChan: api.cbChan}, update)
}

func (api *TgAPI) handleGenerationUpdate(ctx context.Context, g *pollingGeneration, update telego.Update) {
	slog.Info("telegram: raw update received",
		"updateID", update.UpdateID,
		"hasMessage", update.Message != nil,
		"hasCallback", update.CallbackQuery != nil,
	)

	if update.Message != nil && update.Message.Text != "" {
		api.handleMessage(ctx, g, update.Message)
	}

	if update.CallbackQuery != nil {
		api.handleCallbackQuery(ctx, g, update.CallbackQuery)
	}
}

func (api *TgAPI) handleMessage(ctx context.Context, g *pollingGeneration, m *telego.Message) {
	msgID := int64(m.MessageID)
	dedupKey := fmt.Sprintf("%d:%d", m.Chat.ID, msgID)
	if api.isDuplicate(dedupKey) {
		return
	}

	if !api.allowFrom[m.Chat.ID] {
		slog.Warn("telegram: message from unlisted chat ID dropped", "chatID", m.Chat.ID)
		return
	}

	slog.Info("telegram: message received", "chatID", m.Chat.ID, "text", m.Text)
	var senderID int64
	if m.From != nil {
		senderID = m.From.ID
	}

	select {
	case g.msgChan <- bot.InboundMessage{
		ChatID:    m.Chat.ID,
		MessageID: msgID,
		ThreadID:  int64(m.MessageThreadID),
		SenderID:  senderID,
		Text:      m.Text,
	}:
	case <-ctx.Done():
	}
}

func (api *TgAPI) handleCallbackQuery(ctx context.Context, g *pollingGeneration, cb *telego.CallbackQuery) {
	if cb == nil || cb.Message == nil {
		slog.Warn("telegram: callback without message dropped")
		return
	}
	// Both telego message variants may hold a typed nil inside the interface.
	if cb.Message.Message() == nil && cb.Message.InaccessibleMessage() == nil {
		slog.Warn("telegram: callback without message dropped", "id", cb.ID)
		return
	}
	chatID := cb.Message.GetChat().ID
	if chatID == 0 {
		slog.Warn("telegram: callback without chat ID dropped", "id", cb.ID)
		return
	}
	if !api.allowFrom[chatID] {
		slog.Warn("telegram: callback from unlisted chat ID dropped", "chatID", chatID)
		return
	}
	msgID := int64(cb.Message.GetMessageID())
	slog.Info("telegram: callback query received", "id", cb.ID, "from", cb.From.ID)

	// Answer callback immediately to stop loading spinner
	_ = api.breaker.Execute(func() error {
		return api.client.AnswerCallbackQuery(ctx, &telego.AnswerCallbackQueryParams{
			CallbackQueryID: cb.ID,
		})
	})

	slog.Debug("telegram: forwarding callback to channel", "id", cb.ID, "reqID", cb.Data)
	select {
	case g.cbChan <- bot.InboundCallback{
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

// Typing sends a "typing" action to the Telegram chat.
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
		defer RecoverWithStack("telegram-typing")
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

// Send delivers a text message via the Telegram API.
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
		if err != nil {
			return fmt.Errorf("telegram send message: %w", err)
		}
		return nil
	})
	if err != nil && strings.Contains(err.Error(), "can't parse entities") {
		params.ParseMode = ""
		params.Text = msg.Text
		err = api.breaker.Execute(func() error {
			_, err := api.client.SendMessage(ctx, params)
			if err != nil {
				return fmt.Errorf("telegram send message: %w", err)
			}
			return nil
		})
	}
	if err != nil {
		return fmt.Errorf("telego send: %w", err)
	}
	return nil
}

// SendWithButtons delivers a message with an inline keyboard markup.
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
		if err != nil {
			return fmt.Errorf("telegram send with buttons: %w", err)
		}
		return nil
	})
	if err != nil {
		return fmt.Errorf("telego SendWithButtons: %w", err)
	}
	return nil
}

// Stop performs a graceful shutdown of the Telegram API adapter.
func (api *TgAPI) Stop() {
	api.lifecycle.Lock()
	g := api.generation
	if g != nil {
		g.cancel()
	}
	api.lifecycle.Unlock()
	if g != nil {
		<-g.done
	}
}
