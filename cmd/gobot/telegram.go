package main

import (
	"context"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/allthingscode/gobot/internal/bot"
	tgbotapi "github.com/go-telegram-bot-api/telegram-bot-api/v5"
)

type tgAPI struct {
	client    *tgbotapi.BotAPI
	seenMsgs  sync.Map       // int64 (MessageID) -> time.Time (first-seen timestamp)
	allowFrom map[int64]bool // nil or empty = allow all
}

// newTgAPI creates a tgAPI. allowFrom is a list of permitted chat ID strings;
// pass nil or empty slice to allow all senders.
func newTgAPI(token string, allowFrom []string) (*tgAPI, error) {
	client, err := tgbotapi.NewBotAPI(token)
	if err != nil {
		return nil, fmt.Errorf("tgbotapi: %w", err)
	}
	slog.Info("telegram: bot connected", "username", client.Self.UserName)

	af := make(map[int64]bool, len(allowFrom))
	for _, s := range allowFrom {
		if id, err := strconv.ParseInt(s, 10, 64); err == nil {
			af[id] = true
		}
	}

	return &tgAPI{client: client, allowFrom: af}, nil
}

const dedupTTL = 5 * time.Minute

// isDuplicate reports whether msgID was already seen within dedupTTL.
// Stores msgID on first call; evicts expired entries on every call.
func (t *tgAPI) isDuplicate(msgID int64) bool {
	now := time.Now()

	// Opportunistically evict expired entries.
	t.seenMsgs.Range(func(k, v any) bool {
		if now.Sub(v.(time.Time)) >= dedupTTL {
			t.seenMsgs.Delete(k)
		}
		return true
	})

	if v, ok := t.seenMsgs.Load(msgID); ok {
		if now.Sub(v.(time.Time)) < dedupTTL {
			return true
		}
	}
	t.seenMsgs.Store(msgID, now)
	return false
}

func (t *tgAPI) Updates(ctx context.Context, timeout int) (<-chan bot.InboundMessage, error) {
	out := make(chan bot.InboundMessage)

	go func() {
		defer close(out)
		offset := -1 // Start with -1 to clear old updates and get latest
		for {
			select {
			case <-ctx.Done():
				return
			default:
			}

			u := tgbotapi.NewUpdate(offset)
			u.Timeout = 30 // Long poll
			slog.Debug("telegram: polling for updates", "offset", offset, "timeout", 30)
			updates, err := t.client.GetUpdates(u)
			if err != nil {
				slog.Error("telegram: GetUpdates failed", "err", err)
				time.Sleep(5 * time.Second)
				continue
			}

			for _, update := range updates {
				// After the first successful get with -1, we switch to normal offset logic
				if offset == -1 {
					offset = update.UpdateID + 1
				} else if update.UpdateID >= offset {
					offset = update.UpdateID + 1
				}
				slog.Debug("telegram: raw update received", "update_id", update.UpdateID)
				if update.Message == nil || update.Message.Text == "" {
					continue
				}
				msgID := int64(update.Message.MessageID)
				if t.isDuplicate(msgID) {
					continue
				}
				if len(t.allowFrom) > 0 && !t.allowFrom[update.Message.Chat.ID] {
					slog.Warn("telegram: message from unlisted chat ID dropped", "chatID", update.Message.Chat.ID)
					continue
				}
				out <- bot.InboundMessage{
					ChatID:    update.Message.Chat.ID,
					MessageID: msgID,
					ThreadID:  0,
					Text:      update.Message.Text,
				}
			}
		}
	}()

	return out, nil
}

// Typing sends a periodic "typing" action to Telegram.
// Returns a function that, when called, stops the periodic updates.
func (t *tgAPI) Typing(ctx context.Context, chatID, threadID int64) func() {
	stop := make(chan struct{})

	// Send initial typing indicator immediately
	slog.Debug("telegram: sending initial typing action", "chat_id", chatID)
	action := tgbotapi.NewChatAction(chatID, tgbotapi.ChatTyping)
	_, err := t.client.Request(action)
	if err != nil {
		slog.Debug("telegram: initial typing action failed", "err", err)
	} else {
		slog.Debug("telegram: initial typing action sent")
	}

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
				_, _ = t.client.Request(action)
			}
		}
	}()

	return func() {
		close(stop)
	}
}

// Send delivers an OutboundMessage. Sets ParseMode=ModeMarkdown.
// If Markdown parsing fails, it falls back to plain text.
// Sets ReplyToMessageID if msg.ReplyToID > 0.
func (t *tgAPI) Send(ctx context.Context, msg bot.OutboundMessage) error {
	mc := tgbotapi.NewMessage(msg.ChatID, msg.Text)
	mc.ParseMode = tgbotapi.ModeMarkdown
	if msg.ReplyToID > 0 {
		mc.ReplyToMessageID = int(msg.ReplyToID)
	}
	_, err := t.client.Send(mc)
	if err != nil {
		// Fallback for markdown parsing errors
		if strings.Contains(err.Error(), "can't parse entities") {
			mc.ParseMode = "" // Plain text
			_, err = t.client.Send(mc)
		}
	}
	if err != nil {
		return fmt.Errorf("tgbotapi send: %w", err)
	}
	return nil
}

func (t *tgAPI) Stop() {
	t.client.StopReceivingUpdates()
}
