package app

import (
	"context"
	"fmt"
	"html"
	"log/slog"
	"path/filepath"
	"time"

	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/cron"
	"github.com/allthingscode/gobot/internal/integrations/google"
)

func (cd *CronDispatcher) newEmailService(ctx context.Context) (*google.Service, error) {
	svc, err := google.NewService(ctx, filepath.Join(cd.secretsRoot, "gmail"))
	if err != nil {
		return nil, fmt.Errorf("gmail service: %w", err)
	}
	return svc, nil
}

func (cd *CronDispatcher) dispatchEmail(ctx context.Context, p cron.Payload, to string) error {
	recipient := to
	if recipient == "" {
		recipient = cd.userEmail
	}
	if recipient == "" {
		slog.Warn("unroutable cron job: email recipient not set", "job", p.Message)
		return nil
	}

	jobID := p.ID
	if jobID == "" {
		jobID = "unknown"
	}
	sessionKey := bot.SessionPrefixCron + jobID + ":" + chanEmail + ":" + recipient
	slog.Info("dispatching cron job", "session", sessionKey, "channel", chanEmail)

	msg := cd.buildEmailDispatchMessage(p)

	response, err := cd.mgr.Dispatch(ctx, sessionKey, "", msg)
	if err != nil {
		cd.handleMorningBriefingDispatchFailure(ctx, p, recipient, sessionKey, err)
		return &cron.AlreadyNotifiedError{Err: fmt.Errorf("dispatch email: %w", err)}
	}
	if isMorningBriefingJob(p.ID) {
		if guardErr := cd.enforceMorningBriefingGuards(sessionKey, response); guardErr != nil {
			cd.handleMorningBriefingDispatchFailure(ctx, p, recipient, sessionKey, guardErr)
			return &cron.AlreadyNotifiedError{Err: fmt.Errorf("dispatch email validation: %w", guardErr)}
		}
	}

	if response != "" {
		cd.sendEmailResponse(ctx, p, recipient, response)
	}
	return nil
}

func (cd *CronDispatcher) buildEmailDispatchMessage(p cron.Payload) string {
	msg := "[AUTONOMOUS] " + p.Message
	if !isMorningBriefingJob(p.ID) {
		return msg
	}
	if freshCtx := loadScheduleContext(cd.secretsRoot); freshCtx != "" {
		msg = freshCtx + "\n\n" + msg
	}
	return msg
}

func buildCronFailureEmailBody(p cron.Payload, sessionKey string, dispatchErr error) string {
	now := time.Now().Format(time.RFC3339)
	return fmt.Sprintf(
		"<h1>Cron Briefing Status: Partial/Unavailable</h1>"+
			"<p>I could not retrieve all required live information for this run.</p>"+
			"<ul>"+
			"<li><strong>Job ID:</strong> %s</li>"+
			"<li><strong>Session:</strong> %s</li>"+
			"<li><strong>Timestamp:</strong> %s</li>"+
			"<li><strong>Error Hint:</strong> %s</li>"+
			"</ul>"+
			"<p>This email was sent intentionally so you still receive a status update even when live research fails.</p>",
		html.EscapeString(p.ID),
		html.EscapeString(sessionKey),
		html.EscapeString(now),
		html.EscapeString(dispatchErr.Error()),
	)
}

func (cd *CronDispatcher) sendEmailResponse(ctx context.Context, p cron.Payload, recipient, response string) {
	svc, err := cd.newEmailService(ctx)
	if err != nil {
		slog.Error("failed to initialize gmail service for cron", "err", err)
		return
	}
	subject := resolveEmailSubject(p)
	content := buildEmailContent(cd.tmgr, subject, response)
	if err := svc.Send(ctx, recipient, content); err != nil {
		slog.Error("failed to send cron response via email", "err", err, "to", recipient)
	}
}

func resolveFailureEmailSubject(p cron.Payload) string {
	return "⚠️ Failed: " + resolveEmailSubject(p)
}

func (cd *CronDispatcher) sendFailureEmail(ctx context.Context, p cron.Payload, recipient, body string) {
	if cd.failureEmailHook != nil {
		cd.failureEmailHook(ctx, p, recipient, body)
		return
	}
	svc, err := cd.newEmailService(ctx)
	if err != nil {
		slog.Error("failed to initialize gmail service for cron failure email", "err", err)
		return
	}
	subject := resolveFailureEmailSubject(p)
	content := buildEmailContent(cd.tmgr, subject, body)
	if err := svc.Send(ctx, recipient, content); err != nil {
		slog.Error("failed to send cron failure email", "err", err, "to", recipient)
	}
}

// resolveEmailSubject builds the email subject line from the payload.
func resolveEmailSubject(p cron.Payload) string {
	if p.Subject != "" {
		return resolvePlaceholders(p.Subject)
	}
	return "Gobot Strategic Briefing"
}
