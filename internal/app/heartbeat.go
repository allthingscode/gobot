package app

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/doctor"
)

// AlertSender is the minimal interface needed by HeartbeatRunner to send Telegram alerts.
type AlertSender interface {
	Send(ctx context.Context, msg bot.OutboundMessage) error
}

// HeartbeatRunner runs periodic health checks and sends alerts on failures.
type HeartbeatRunner struct {
	probes           *doctor.Probes
	sender           AlertSender // may be nil; no alerts sent if nil or alertChatID==0
	alertChatID      int64       // primary user chat ID; 0 = no alerts
	storageRoot      string
	apiKey           string
	tgToken          string
	gmailSecretsPath string // directory containing token.json; empty = skip Gmail probe
	interval         time.Duration
}

// NewHeartbeatRunner constructs a HeartbeatRunner using config and token.
func NewHeartbeatRunner(cfg *config.Config, token string) *HeartbeatRunner {
	return &HeartbeatRunner{
		probes:           LiveProbesList(),
		alertChatID:      cfg.Strategic.UserChatID,
		storageRoot:      cfg.StorageRoot(),
		apiKey:           cfg.GeminiAPIKey(),
		tgToken:          token,
		gmailSecretsPath: filepath.Join(cfg.SecretsRoot(), "gmail"),
		interval:         cfg.HeartbeatInterval(),
	}
}

// Run starts the heartbeat ticker loop. Blocks until ctx is cancelled.
func (hb *HeartbeatRunner) Run(ctx context.Context) {
	ticker := time.NewTicker(hb.interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			hb.check(ctx)
		}
	}
}

type probeResult struct {
	name string
	err  error
}

func (hb *HeartbeatRunner) check(ctx context.Context) {
	failures := hb.runProbes()
	hb.writeLivenessFile(len(failures))

	if len(failures) == 0 {
		slog.Debug("heartbeat: all probes OK")
		return
	}

	hb.logFailures(failures)
	hb.sendAlert(ctx, failures)
}

func (hb *HeartbeatRunner) runProbes() []probeResult {
	if hb.probes == nil {
		return nil
	}

	var failures []probeResult //nolint:prealloc // capacity requires calling all probe functions twice
	failures = append(failures, hb.probeTelegram()...)
	failures = append(failures, hb.probeGemini()...)
	failures = append(failures, hb.probeGmail()...)

	return failures
}

func (hb *HeartbeatRunner) probeTelegram() []probeResult {
	if hb.probes.ProbeTelegram != nil && hb.tgToken != "" {
		if _, err := hb.probes.ProbeTelegram(hb.tgToken); err != nil {
			return []probeResult{{"Telegram", err}}
		}
	}
	return nil
}

func (hb *HeartbeatRunner) probeGemini() []probeResult {
	if hb.probes.ProbeGemini != nil && hb.apiKey != "" {
		if err := hb.probes.ProbeGemini(hb.apiKey); err != nil {
			return []probeResult{{"Gemini", err}}
		}
	}
	return nil
}

func (hb *HeartbeatRunner) probeGmail() []probeResult {
	if hb.probes.ProbeGmail != nil && hb.gmailSecretsPath != "" {
		if err := hb.probes.ProbeGmail(hb.gmailSecretsPath); err != nil && !errors.Is(err, os.ErrNotExist) {
			return []probeResult{{"Gmail", err}}
		}
	}
	return nil
}

func (hb *HeartbeatRunner) writeLivenessFile(failureCount int) {
	livenessPath := filepath.Join(hb.storageRoot, "LIVENESS")
	livenessContent := fmt.Sprintf("ok %s failures=%d\n", time.Now().UTC().Format(time.RFC3339), failureCount)
	if err := os.WriteFile(livenessPath, []byte(livenessContent), 0o600); err != nil {
		slog.Warn("heartbeat: failed to write LIVENESS file", "err", err)
	}
}

func (hb *HeartbeatRunner) logFailures(failures []probeResult) {
	for _, f := range failures {
		slog.Warn("heartbeat: probe failed", "service", f.name, "err", f.err)
	}
}

func (hb *HeartbeatRunner) sendAlert(ctx context.Context, failures []probeResult) {
	if hb.sender == nil || hb.alertChatID == 0 {
		return
	}

	lines := make([]string, len(failures))
	for i, f := range failures {
		lines[i] = fmt.Sprintf("- %s: %v", f.name, f.err)
	}
	alertText := fmt.Sprintf("[gobot] Partial Outage at %s:\n%s",
		time.Now().UTC().Format(time.RFC3339),
		strings.Join(lines, "\n"),
	)
	if err := hb.sender.Send(ctx, bot.OutboundMessage{
		ChatID: hb.alertChatID,
		Text:   alertText,
	}); err != nil {
		slog.Warn("heartbeat: failed to send alert", "err", err)
	}
}
