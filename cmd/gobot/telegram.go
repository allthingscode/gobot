package main

import (
	"context"
	"fmt"
	"sync"
	"time"

	tgbotapi "github.com/go-telegram-bot-api/telegram-bot-api/v5"
	"github.com/allthingscode/gobot/internal/bot"
)

type tgAPI struct {
	client   *tgbotapi.BotAPI
	seenMsgs sync.Map // int64 (MessageID) -> time.Time (first-seen timestamp)
}

func newTgAPI(token string) (*tgAPI, error) {
	client, err := tgbotapi.NewBotAPI(token)
	if err != nil {
		return nil, fmt.Errorf("tgbotapi: %w", err)
	}
	return &tgAPI{client: client}, nil
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

// Updates bridges tgbotapi updates to bot.InboundMessage.
// Spawns a goroutine. Returned channel is closed when ctx is cancelled or raw channel closes.
// Only forwards updates where Message != nil and Text != "".
// ThreadID is always 0 (not supported in tgbotapi v5.5.1).
func (t *tgAPI) Updates(ctx context.Context, timeout int) (<-chan bot.InboundMessage, error) {
	u := tgbotapi.NewUpdate(0)
	u.Timeout = timeout
	updates := t.client.GetUpdatesChan(u)

	out := make(chan bot.InboundMessage)

	go func() {
		defer close(out)
		for {
			select {
			case <-ctx.Done():
				return
			case update, ok := <-updates:
				if !ok {
					return
				}
				if update.Message == nil || update.Message.Text == "" {
					continue
				}
				msgID := int64(update.Message.MessageID)
				if t.isDuplicate(msgID) {
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

// Send delivers an OutboundMessage. Sets ParseMode=ModeMarkdown.
// Sets ReplyToMessageID if msg.ReplyToID > 0.
func (t *tgAPI) Send(ctx context.Context, msg bot.OutboundMessage) error {
	mc := tgbotapi.NewMessage(msg.ChatID, msg.Text)
	mc.ParseMode = tgbotapi.ModeMarkdown
	if msg.ReplyToID > 0 {
		mc.ReplyToMessageID = int(msg.ReplyToID)
	}
	_, err := t.client.Send(mc)
	if err != nil {
		return fmt.Errorf("tgbotapi send: %w", err)
	}
	return nil
}

func (t *tgAPI) Stop() {
	t.client.StopReceivingUpdates()
}
