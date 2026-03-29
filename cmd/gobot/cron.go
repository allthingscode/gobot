package main

import (
	"context"
	"fmt"
	"log/slog"
	"strconv"
	"strings"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/cron"
)

// cronDispatcher implements cron.Dispatcher.
// It routes job payloads to the agent SessionManager and sends
// any non-empty response back via the Telegram bot.
type cronDispatcher struct {
	mgr         *agent.SessionManager
	b           *bot.Bot
	storageRoot string
}

// Dispatch routes a cron job payload to the agent and sends the reply.
//
// Steps:
//  1. Call cron.ResolveRoutableChannel(p, storageRoot).
//     - If silent == true: prepend "[SILENT] " to message, then dispatch (no reply sent).
//     - If channel != "telegram" or to == "": log and return nil (unroutable).
//  2. Use `to` directly as the sessionKey for mgr.Dispatch.
//  3. If silent == false and response != "": parse sessionKey into chatID + threadID
//     and call b.Send() with the response.
func (d *cronDispatcher) Dispatch(ctx context.Context, p cron.Payload) error {
	channel, to, silent := cron.ResolveRoutableChannel(p, d.storageRoot)

	if silent {
		if p.To == "" {
			slog.Warn("unroutable cron job", "channel", channel, "to", to)
			return nil
		}
		sessionKey := "cron:" + p.To
		slog.Info("dispatching cron job", "sessionKey", sessionKey, "silent", true)
		_, err := d.mgr.Dispatch(ctx, sessionKey, "[SILENT] "+p.Message)
		return err
	}

	if channel != "telegram" || to == "" {
		slog.Warn("unroutable cron job", "channel", channel, "to", to)
		return nil
	}

	sessionKey := "cron:" + to
	slog.Info("dispatching cron job", "sessionKey", sessionKey, "silent", false)
	response, err := d.mgr.Dispatch(ctx, sessionKey, p.Message)
	if err != nil {
		return err
	}

	if response != "" {
		chatID, threadID, err := parseSessionKey(to)
		if err != nil {
			slog.Error("failed to parse session key for reply", "sessionKey", to, "err", err)
			return nil
		}
		out := bot.OutboundMessage{
			ChatID:   chatID,
			ThreadID: threadID,
			Text:     response,
		}
		if err := d.b.Send(ctx, out); err != nil {
			slog.Error("failed to send cron response", "err", err, "sessionKey", to)
		}
	}

	return nil
}

// parseSessionKey parses "telegram:12345" or "telegram:12345:7"
// into chatID and threadID. Returns error if the key is malformed.
// Examples:
//
//	"telegram:12345"    -> chatID=12345, threadID=0
//	"telegram:12345:7"  -> chatID=12345, threadID=7
func parseSessionKey(sessionKey string) (chatID, threadID int64, err error) {
	parts := strings.Split(sessionKey, ":")
	if len(parts) < 2 || len(parts) > 3 {
		return 0, 0, fmt.Errorf("invalid session key format: %s", sessionKey)
	}
	if parts[0] != "telegram" {
		return 0, 0, fmt.Errorf("unsupported channel in session key: %s", parts[0])
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
