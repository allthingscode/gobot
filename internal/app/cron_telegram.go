package app

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/cron"
)

func (cd *CronDispatcher) dispatchTelegram(ctx context.Context, p cron.Payload, to string) error {
	sessionKey := bot.SessionPrefixCron + to
	slog.Info("dispatching cron job", "session", sessionKey, "silent", false)
	response, err := cd.mgr.Dispatch(ctx, sessionKey, "", "[AUTONOMOUS] "+p.Message)
	if err != nil {
		return fmt.Errorf("dispatch telegram: %w", err)
	}

	if response != "" {
		cd.sendTelegramResponse(ctx, to, response)
	}
	return nil
}

func (cd *CronDispatcher) sendTelegramResponse(ctx context.Context, to, response string) {
	chatID, threadID, err := parseSessionKey(to)
	if err != nil {
		slog.Error("failed to parse session key for reply", "session", to, "err", err)
		return
	}
	out := bot.OutboundMessage{
		ChatID:   chatID,
		ThreadID: threadID,
		Text:     response,
	}
	if err := cd.b.Send(ctx, out); err != nil {
		slog.Error("failed to send cron response", "err", err, "session", to)
	}
}
