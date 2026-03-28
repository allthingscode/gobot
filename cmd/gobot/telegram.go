package main

import (
	"context"
	"fmt"
	"log/slog"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/allthingscode/gobot/internal/bot"
	tgbotapi "github.com/go-telegram-bot-api/telegram-bot-api/v5"
)

// mdV2CodeRe matches fenced code blocks (```...```) and inline code (`...`)
// so they can be preserved unchanged during MarkdownV2 escaping.
var mdV2CodeRe = regexp.MustCompile("(?s)(```[\\s\\S]*?```|`[^`\\n]+`)")

// escapeMarkdownV2Chars escapes all Telegram MarkdownV2 special characters in s.
// The backslash is escaped first to avoid double-escaping.
func escapeMarkdownV2Chars(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	for _, ch := range []string{"_", "*", "[", "]", "(", ")", "~", "`", ">", "#", "+", "-", "=", "|", "{", "}", ".", "!"} {
		s = strings.ReplaceAll(s, ch, `\`+ch)
	}
	return s
}

// convertToMarkdownV2 prepares text for Telegram ModeMarkdownV2.
// Fenced code blocks and inline code are preserved verbatim.
// All other MarkdownV2 special characters in surrounding text are escaped
// so they render literally and never cause a parse error.
func convertToMarkdownV2(text string) string {
	parts := mdV2CodeRe.Split(text, -1)
	codes := mdV2CodeRe.FindAllString(text, -1)

	var b strings.Builder
	for i, part := range parts {
		b.WriteString(escapeMarkdownV2Chars(part))
		if i < len(codes) {
			b.WriteString(codes[i])
		}
	}
	return b.String()
}

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

// Send delivers an OutboundMessage using Telegram MarkdownV2 mode.
// Text is converted via convertToMarkdownV2: code blocks are preserved verbatim
// and all other special characters are escaped, so parse errors cannot occur.
// Falls back to plain text only if the API rejects the converted message.
// Sets ReplyToMessageID if msg.ReplyToID > 0.
func (t *tgAPI) Send(ctx context.Context, msg bot.OutboundMessage) error {
	mc := tgbotapi.NewMessage(msg.ChatID, convertToMarkdownV2(msg.Text))
	mc.ParseMode = tgbotapi.ModeMarkdownV2
	if msg.ReplyToID > 0 {
		mc.ReplyToMessageID = int(msg.ReplyToID)
	}
	_, err := t.client.Send(mc)
	if err != nil && strings.Contains(err.Error(), "can't parse entities") {
		// Defensive fallback: send original text as plain
		mc.ParseMode = ""
		mc.Text = msg.Text
		_, err = t.client.Send(mc)
	}
	if err != nil {
		return fmt.Errorf("tgbotapi send: %w", err)
	}
	return nil
}

func (t *tgAPI) Stop() {
	t.client.StopReceivingUpdates()
}
