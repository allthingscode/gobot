package main

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
	"github.com/allthingscode/gobot/internal/doctor"
)

const heartbeatInterval = 15 * time.Minute

// alertSender is the minimal interface needed by heartbeatRunner to send Telegram alerts.
type alertSender interface {
	Send(ctx context.Context, msg bot.OutboundMessage) error
}

// heartbeatRunner runs periodic health checks and sends alerts on failures.
type heartbeatRunner struct {
	probes           *doctor.Probes
	sender           alertSender // may be nil; no alerts sent if nil or alertChatID==0
	alertChatID      int64       // primary user chat ID; 0 = no alerts
	storageRoot      string
	apiKey           string
	tgToken          string
	gmailSecretsPath string // directory containing token.json; empty = skip Gmail probe
}

// newHeartbeatRunner constructs a heartbeatRunner.
func newHeartbeatRunner(
	probes *doctor.Probes,
	sender alertSender,
	alertChatID int64,
	storageRoot, apiKey, tgToken, gmailSecretsPath string,
) *heartbeatRunner {
	return &heartbeatRunner{
		probes:           probes,
		sender:           sender,
		alertChatID:      alertChatID,
		storageRoot:      storageRoot,
		apiKey:           apiKey,
		tgToken:          tgToken,
		gmailSecretsPath: gmailSecretsPath,
	}
}

// Run starts the heartbeat ticker loop. Blocks until ctx is cancelled.
func (h *heartbeatRunner) Run(ctx context.Context) {
	ticker := time.NewTicker(heartbeatInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			h.check(ctx)
		}
	}
}

// check performs one health-check cycle: probes APIs, writes LIVENESS, sends alert on failure.
func (h *heartbeatRunner) check(ctx context.Context) {
	type probeResult struct {
		name string
		err  error
	}

	var failures []probeResult

	// Probe Telegram
	if h.probes != nil && h.probes.ProbeTelegram != nil && h.tgToken != "" {
		if _, err := h.probes.ProbeTelegram(h.tgToken); err != nil {
			failures = append(failures, probeResult{"Telegram", err})
		}
	}

	// Probe Gemini
	if h.probes != nil && h.probes.ProbeGemini != nil && h.apiKey != "" {
		if err := h.probes.ProbeGemini(h.apiKey); err != nil {
			failures = append(failures, probeResult{"Gemini", err})
		}
	}

	// Probe Gmail — skip silently if token file does not exist (not yet configured).
	if h.probes != nil && h.probes.ProbeGmail != nil && h.gmailSecretsPath != "" {
		if err := h.probes.ProbeGmail(h.gmailSecretsPath); err != nil && !errors.Is(err, os.ErrNotExist) {
			failures = append(failures, probeResult{"Gmail", err})
		}
	}

	// Write LIVENESS file to storageRoot.
	livenessPath := filepath.Join(h.storageRoot, "LIVENESS")
	livenessContent := fmt.Sprintf("ok %s failures=%d\n", time.Now().UTC().Format(time.RFC3339), len(failures))
	if err := os.WriteFile(livenessPath, []byte(livenessContent), 0o600); err != nil {
		slog.Warn("heartbeat: failed to write LIVENESS file", "err", err)
	}

	if len(failures) == 0 {
		slog.Debug("heartbeat: all probes OK")
		return
	}

	for _, f := range failures {
		slog.Warn("heartbeat: probe failed", "service", f.name, "err", f.err)
	}

	// Send Telegram alert if sender and chat ID are configured.
	if h.sender == nil || h.alertChatID == 0 {
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
	if err := h.sender.Send(ctx, bot.OutboundMessage{
		ChatID: h.alertChatID,
		Text:   alertText,
	}); err != nil {
		slog.Warn("heartbeat: failed to send alert", "err", err)
	}
}
