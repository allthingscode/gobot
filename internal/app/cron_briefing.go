package app

import (
	"context"
	"fmt"
	"log/slog"
	"regexp"
	"strings"
	"time"

	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/cron"
)

func isMorningBriefingJob(jobID string) bool {
	return strings.EqualFold(strings.TrimSpace(jobID), morningBriefingJobID)
}

func shouldRetryMorningBriefingAfterError(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	if strings.Contains(msg, "auth_expired") ||
		strings.Contains(msg, "invalid_grant") ||
		strings.Contains(msg, "run gobot reauth") ||
		strings.Contains(msg, "run gobot reauth-google") {
		return false
	}
	return true
}

func (cd *CronDispatcher) handleMorningBriefingDispatchFailure(ctx context.Context, p cron.Payload, recipient, sessionKey string, err error) {
	cd.sendFailureEmail(ctx, p, recipient, buildCronFailureEmailBody(p, sessionKey, err))
	if isMorningBriefingJob(p.ID) && shouldRetryMorningBriefingAfterError(err) {
		go cd.retryMorningBriefing(cd.shutdownCh, p, recipient, []time.Duration{30 * time.Minute, 90 * time.Minute}) //nolint:gosec // retry intentionally outlives the request context
	}
}

func (cd *CronDispatcher) enforceMorningBriefingGuards(sessionKey, response string) error {
	if err := validateMorningBriefingResponse(response); err != nil {
		return err
	}
	ok, err := cd.verifySearchToolProvenance(sessionKey)
	if err != nil {
		return fmt.Errorf("provenance check failed: %w", err)
	}
	if !ok {
		return fmt.Errorf("provenance check failed: no live search tool usage found in session transcript")
	}
	return nil
}

func validateMorningBriefingResponse(response string) error {
	body := strings.TrimSpace(response)
	if body == "" {
		return fmt.Errorf("empty response")
	}
	if strings.Contains(body, "Daily Briefing Status: Partial/Unavailable") {
		return fmt.Errorf("response reports partial or unavailable briefing status")
	}
	if strings.Contains(body, "TOOL_ERROR") {
		return fmt.Errorf("response contains TOOL_ERROR marker")
	}
	// Require at least one source attribution (partial briefs may have fewer sections).
	if strings.Count(body, "[Sources:") < 1 {
		return fmt.Errorf("no source attributions found")
	}
	// Require at least one published date.
	dateRe := regexp.MustCompile(`\b20\d{2}-\d{2}-\d{2}\b`)
	if len(dateRe.FindAllString(body, -1)) < 1 {
		return fmt.Errorf("no published dates in output")
	}
	return nil
}

func (cd *CronDispatcher) retryMorningBriefing(shutdown <-chan struct{}, p cron.Payload, recipient string, delays []time.Duration) {
	startedAt := time.Now()
	msg := cd.buildEmailDispatchMessage(p)
	for i, delay := range delays {
		slog.Info("cron: morning briefing retry scheduled", "attempt", i+1, "delay", delay)
		if !waitUntilRetryDelay(shutdown, startedAt, delay) {
			slog.Info("cron: morning briefing retry cancelled (shutdown)")
			return
		}

		select {
		case <-shutdown:
			slog.Info("cron: morning briefing retry cancelled before attempt", "attempt", i+1)
			return
		default:
		}

		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Minute) //nolint:gosec // retry goroutine must outlive the triggering request context
		retryKey := fmt.Sprintf("%s%s:email:%s:retry%d", bot.SessionPrefixCron, morningBriefingJobID, recipient, i+1)

		slog.Info("cron: retrying morning briefing", "session", retryKey, "attempt", i+1)
		response, err := cd.retryDispatch(ctx, retryKey, msg)
		if err != nil {
			cancel()
			slog.Error("cron: morning briefing retry failed", "err", err, "attempt", i+1)
			cd.sendRetryFailureEmail(p, recipient, retryKey, err)
			continue
		}
		if err := cd.retryEnforceGuards(retryKey, response); err != nil {
			cancel()
			slog.Error("cron: morning briefing retry failed validation", "err", err, "attempt", i+1)
			cd.sendRetryFailureEmail(p, recipient, retryKey, err)
			continue
		}
		if response != "" {
			slog.Info("cron: morning briefing retry succeeded, delivering email", "attempt", i+1)
			cd.sendEmailResponse(ctx, p, recipient, response)
		}
		cancel()
		return
	}
}

func waitUntilRetryDelay(shutdown <-chan struct{}, startedAt time.Time, targetDelay time.Duration) bool {
	wait := time.Until(startedAt.Add(targetDelay))
	if wait <= 0 {
		return true
	}
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case <-timer.C:
		return true
	case <-shutdown:
		return false
	}
}

func (cd *CronDispatcher) retryDispatch(ctx context.Context, retryKey, msg string) (string, error) {
	if cd.dispatchHook != nil {
		return cd.dispatchHook(ctx, retryKey, msg)
	}
	response, err := cd.mgr.Dispatch(ctx, retryKey, "", msg)
	if err != nil {
		return "", fmt.Errorf("retry dispatch: %w", err)
	}
	return response, nil
}

func (cd *CronDispatcher) retryEnforceGuards(retryKey, response string) error {
	if cd.guardHook != nil {
		return cd.guardHook(retryKey, response)
	}
	return cd.enforceMorningBriefingGuards(retryKey, response)
}

func (cd *CronDispatcher) sendRetryFailureEmail(p cron.Payload, recipient, retryKey string, err error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cd.sendFailureEmail(ctx, p, recipient, buildCronFailureEmailBody(p, retryKey, fmt.Errorf("retry also failed: %w", err)))
}
