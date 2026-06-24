package app

import (
	"context"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"time"

	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/cron"
)

// Alert sends a failure notification directly via Telegram, bypassing the agent
// runner. This prevents a cascading failure when the runner itself is the error source.
func (cd *CronDispatcher) Alert(ctx context.Context, p cron.Payload) error {
	channel, to, _ := cron.ResolveRoutableChannel(p, cd.storageRoot)
	if channel == chanEmail {
		recipient := to
		if recipient == "" {
			recipient = cd.userEmail
		}
		if recipient == "" {
			slog.Warn("CronDispatcher.Alert: unroutable email alert, no recipient configured", "channel", channel)
			return nil
		}
		alertPayload := p
		if alertPayload.Subject == "" {
			alertPayload.Subject = "Gobot Alert"
		}
		cd.sendEmailResponse(ctx, alertPayload, recipient, p.Message)
		return nil
	}
	if to == "" {
		slog.Warn("CronDispatcher.Alert: unroutable payload, dropping", "channel", p.Channel)
		return nil
	}
	chatID, threadID, err := parseSessionKey(to)
	if err != nil {
		return fmt.Errorf("CronDispatcher.Alert: %w", err)
	}
	if err := cd.b.Send(ctx, bot.OutboundMessage{
		ChatID:   chatID,
		ThreadID: threadID,
		Text:     p.Message,
	}); err != nil {
		return fmt.Errorf("alert send: %w", err)
	}
	return nil
}

// parseSessionKey parses "telegram:12345" or "telegram:12345:7"
// into chatID and threadID. Returns error if the key is malformed.
func parseSessionKey(sessionKey string) (chatID, threadID int64, err error) {
	if !bot.IsTelegramSession(sessionKey) {
		return 0, 0, fmt.Errorf("unsupported channel in session key: %s", sessionKey)
	}
	parts := strings.Split(sessionKey, ":")
	if len(parts) < 2 || len(parts) > 3 {
		return 0, 0, fmt.Errorf("invalid session key format: %s", sessionKey)
	}

	chatID, err = strconv.ParseInt(parts[1], 10, 64)
	if err != nil {
		return 0, 0, fmt.Errorf("invalid chat ID: %w", err)
	}

	if len(parts) == 3 {
		threadID, err = strconv.ParseInt(parts[2], 10, 64)
		if err != nil {
			return 0, 0, fmt.Errorf("invalid thread ID: %w", err)
		}
	}

	return chatID, threadID, nil
}

func resolvePlaceholders(text string) string {
	now := time.Now()
	dateStr := fmt.Sprintf("%s %d, %d", now.Format("January"), now.Day(), now.Year())
	return strings.ReplaceAll(text, "{{DATE}}", dateStr)
}
