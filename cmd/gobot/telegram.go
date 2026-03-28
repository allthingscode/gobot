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
	"github.com/mymmrac/telego"
)

// mdV2CodeRe matches fenced code blocks (```...```) and inline code (`)
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
	client    *telego.Bot
	seenMsgs  sync.Map
	allowFrom map[int64]bool
}

func newTgAPI(token string, allowFrom []string) (*tgAPI, error) {
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
		offset := 0
		for {
			select {
			case <-ctx.Done():
				return
			default:
			}

			updates, err := t.client.GetUpdates(ctx, &telego.GetUpdatesParams{
				Offset:  offset,
				Timeout: 30,
			})
			if err != nil {
				slog.Error("telegram: GetUpdates failed", "err", err)
				time.Sleep(5 * time.Second)
				continue
			}

			for _, update := range updates {
				if update.UpdateID >= offset {
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
				var senderID int64
				if update.Message.From != nil {
					senderID = update.Message.From.ID
				}
				out <- bot.InboundMessage{
					ChatID:    update.Message.Chat.ID,
					MessageID: msgID,
					ThreadID:  int64(update.Message.MessageThreadID),
					SenderID:  senderID,
					Text:      update.Message.Text,
				}
			}
		}
	}()
	return out, nil
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
		if err := t.client.SendChatAction(ctx, params); err != nil {
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
		Text:      convertToMarkdownV2(msg.Text),
		ParseMode: telego.ModeMarkdownV2,
	}
	if msg.ThreadID > 0 {
		params.MessageThreadID = int(msg.ThreadID)
	}
	if msg.ReplyToID > 0 {
		params.ReplyParameters = &telego.ReplyParameters{MessageID: int(msg.ReplyToID)}
	}
	_, err := t.client.SendMessage(ctx, params)
	if err != nil && strings.Contains(err.Error(), "can't parse entities") {
		params.ParseMode = ""
		params.Text = msg.Text
		_, err = t.client.SendMessage(ctx, params)
	}
	if err != nil {
		return fmt.Errorf("telego send: %w", err)
	}
	return nil
}

func (t *tgAPI) Stop() {}
