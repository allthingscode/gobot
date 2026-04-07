package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/doctor"
)

type mockAlertSender struct {
	sent []bot.OutboundMessage
}

func (m *mockAlertSender) Send(_ context.Context, msg bot.OutboundMessage) error {
	m.sent = append(m.sent, msg)
	return nil
}

func TestHeartbeatCheck(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name             string
		telegramErr      error
		geminiErr        error
		gmailErr         error
		alertChatID      int64
		wantAlertCount   int
		wantLivenessSnip string // substring expected in LIVENESS file
	}{
		{
			name:             "all probes OK",
			wantAlertCount:   0,
			wantLivenessSnip: "failures=0",
		},
		{
			name:             "telegram fail triggers alert",
			telegramErr:      os.ErrDeadlineExceeded,
			alertChatID:      42,
			wantAlertCount:   1,
			wantLivenessSnip: "failures=1",
		},
		{
			name:             "gemini fail triggers alert",
			geminiErr:        os.ErrDeadlineExceeded,
			alertChatID:      42,
			wantAlertCount:   1,
			wantLivenessSnip: "failures=1",
		},
		{
			name:             "gmail ErrNotExist is not a failure",
			gmailErr:         os.ErrNotExist,
			alertChatID:      42,
			wantAlertCount:   0,
			wantLivenessSnip: "failures=0",
		},
		{
			name:             "gmail real error triggers alert",
			gmailErr:         os.ErrPermission,
			alertChatID:      42,
			wantAlertCount:   1,
			wantLivenessSnip: "failures=1",
		},
		{
			name:             "no alert chat ID suppresses message",
			telegramErr:      os.ErrDeadlineExceeded,
			alertChatID:      0,
			wantAlertCount:   0,
			wantLivenessSnip: "failures=1",
		},
		{
			name:             "multiple failures bundled in one alert",
			telegramErr:      os.ErrDeadlineExceeded,
			geminiErr:        os.ErrDeadlineExceeded,
			alertChatID:      99,
			wantAlertCount:   1,
			wantLivenessSnip: "failures=2",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
		t.Parallel()
			dir := t.TempDir()
			sender := &mockAlertSender{}

			hb := &heartbeatRunner{
				probes: &doctor.Probes{
					ProbeTelegram: func(_ string) (string, error) {
						return "", tc.telegramErr
					},
					ProbeGemini: func(_ string) error {
						return tc.geminiErr
					},
					ProbeGmail: func(_ string) error {
						return tc.gmailErr
					},
				},
				sender:           sender,
				alertChatID:      tc.alertChatID,
				storageRoot:      dir,
				tgToken:          "fake-token",
				apiKey:           "fake-key",
				gmailSecretsPath: filepath.Join(dir, "gmail"),
			}

			hb.check(context.Background())

			if got := len(sender.sent); got != tc.wantAlertCount {
				t.Errorf("alerts sent: got %d, want %d", got, tc.wantAlertCount)
			}

			data, err := os.ReadFile(filepath.Join(dir, "LIVENESS"))
			if err != nil {
				t.Fatalf("LIVENESS file not written: %v", err)
			}
			if !strings.Contains(string(data), tc.wantLivenessSnip) {
				t.Errorf("LIVENESS %q does not contain %q", string(data), tc.wantLivenessSnip)
			}
		})
	}
}
