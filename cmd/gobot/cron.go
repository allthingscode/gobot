package main

import (
        "context"
        "fmt"
        "log/slog"
        "path/filepath"
        "strconv"
        "strings"
        "time"

        "github.com/allthingscode/gobot/internal/agent"
        "github.com/allthingscode/gobot/internal/bot"
        "github.com/allthingscode/gobot/internal/cron"
        "github.com/allthingscode/gobot/internal/integrations/google"
        "github.com/allthingscode/gobot/internal/memory/vector"
)

// cronDispatcher implements cron.Dispatcher.
// It routes job payloads to the agent SessionManager and sends
// any non-empty response back via the Telegram bot.
type cronDispatcher struct {
        mgr         *agent.SessionManager
        b           *bot.Bot
        storageRoot string
        secretsRoot string
        userEmail   string

        vecStore     *vector.Store
        embedProv    vector.EmbeddingProvider
        workspaceDir string
}

// Dispatch routes a cron job payload to the agent and sends the reply.
//
// Steps:
//  1. Call cron.ResolveRoutableChannel(p, storageRoot).
//     - If silent == true: prepend "[SILENT] " to message, then dispatch (no reply sent).
//     - If channel == "email": dispatch and send response via google.
//     - If channel != "telegram" or to == "": log and return nil (unroutable).
//  2. Use `to` directly as the sessionKey for mgr.Dispatch.
//  3. If silent == false and response != "": parse sessionKey into chatID + threadID
//     and call b.Send() with the response.
func (d *cronDispatcher) Dispatch(ctx context.Context, p cron.Payload) error {
        if p.Message == "[SYSTEM] INDEX_WORKSPACE" {
                if d.vecStore != nil && d.embedProv != nil && d.workspaceDir != "" {
                        slog.Info("cron: starting workspace vector indexing")
                        err := vector.IndexWorkspaceMarkdown(ctx, d.vecStore, d.workspaceDir, func(c context.Context, text string) ([]float32, error) {
                                return d.embedProv.Embed(c, text)
                        })
                        if err != nil {
                                slog.Error("cron: vector index error", "err", err)
                                return err
                        }
                        slog.Info("cron: workspace vector indexing complete")
                        return nil
                }
                slog.Warn("cron: vector store not initialized, skipping INDEX_WORKSPACE")
                return nil
        }

        channel, to, silent := cron.ResolveRoutableChannel(p, d.storageRoot)
	if silent {
		if p.To == "" {
			slog.Warn("unroutable cron job", "channel", channel, "to", to)
			return nil
		}
		sessionKey := "cron:" + p.To
		slog.Info("dispatching cron job", "sessionKey", sessionKey, "silent", true)
		_, err := d.mgr.Dispatch(ctx, sessionKey, "", "[SILENT] [AUTONOMOUS] "+p.Message)
		return err
	}

	if channel == "email" {
		recipient := to
		if recipient == "" {
			recipient = d.userEmail
		}
		if recipient == "" {
			slog.Warn("unroutable cron job: email recipient not set", "job", p.Message)
			return nil
		}

		jobID := p.ID
		if jobID == "" {
			jobID = "unknown"
		}
		sessionKey := "cron:" + jobID + ":email:" + recipient
		slog.Info("dispatching cron job", "sessionKey", sessionKey, "channel", "email")
		response, err := d.mgr.Dispatch(ctx, sessionKey, "", "[AUTONOMOUS] "+p.Message)
		if err != nil {
			return err
		}

		if response != "" {
			gmailSecrets := filepath.Join(d.secretsRoot, "gmail")
			svc, err := google.NewService(gmailSecrets)
			if err != nil {
				slog.Error("failed to initialize gmail service for cron", "err", err)
				return fmt.Errorf("init gmail service: %w", err)
			}
			subject := resolveEmailSubject(p)
			if err := svc.Send(ctx, recipient, subject, response); err != nil {
				slog.Error("failed to send cron response via email", "err", err, "to", recipient)
			}
		}
		return nil
	}

	if channel != "telegram" || to == "" {
		slog.Warn("unroutable cron job", "channel", channel, "to", to)
		return nil
	}

	sessionKey := "cron:" + to
	slog.Info("dispatching cron job", "sessionKey", sessionKey, "silent", false)
	response, err := d.mgr.Dispatch(ctx, sessionKey, "", "[AUTONOMOUS] "+p.Message)
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

// Alert sends a failure notification directly via Telegram, bypassing the agent
// runner. This prevents a cascading failure when the runner itself is the error source.
func (d *cronDispatcher) Alert(ctx context.Context, p cron.Payload) error {
	_, to, _ := cron.ResolveRoutableChannel(p, d.storageRoot)
	if to == "" {
		slog.Warn("cronDispatcher.Alert: unroutable payload, dropping", "channel", p.Channel)
		return nil
	}
	chatID, threadID, err := parseSessionKey(to)
	if err != nil {
		return fmt.Errorf("cronDispatcher.Alert: %w", err)
	}
	return d.b.Send(ctx, bot.OutboundMessage{
		ChatID:   chatID,
		ThreadID: threadID,
		Text:     p.Message,
	})
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

// resolveEmailSubject builds the email subject line from the payload.
// If a subject template was provided in the job's front-matter, it is used
// with {{DATE}} replaced by the current date (e.g. "April 4, 2026").
// If no subject template was set, the historic default is used.
func resolveEmailSubject(p cron.Payload) string {
	if p.Subject != "" {
		now := time.Now()
		dateStr := fmt.Sprintf("%s %d, %d", now.Format("January"), now.Day(), now.Year())
		return strings.ReplaceAll(p.Subject, "{{DATE}}", dateStr)
	}
	return "Gobot Strategic Briefing"
}
