//nolint:testpackage // intentionally uses unexported helpers from main package
package app

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/doctor"
)

type mockAlertSender struct {
	sent []bot.OutboundMessage
}

func (m *mockAlertSender) Send(_ context.Context, msg bot.OutboundMessage) error {
	m.sent = append(m.sent, msg)
	return nil
}

// TestNewHeartbeatRunner_WiresSender is the regression for B-003: the production
// constructor must store the injected sender so sendAlert can reach the alert path.
// Before the fix, NewHeartbeatRunner never set sender and alerts could never fire.
func TestNewHeartbeatRunner_WiresSender(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = t.TempDir()
	sender := &mockAlertSender{}

	hb := NewHeartbeatRunner(cfg, "token", sender)
	if hb.sender == nil {
		t.Fatal("NewHeartbeatRunner did not wire the injected sender (B-003 regression)")
	}
}

// TestAlertSenderFromAPI_NilReturnsNilInterface guards the typed-nil pitfall: a nil
// *TgAPI must become a true nil AlertSender interface, otherwise sendAlert's nil check
// is defeated and Send panics on a nil pointer.
func TestAlertSenderFromAPI_NilReturnsNilInterface(t *testing.T) {
	t.Parallel()
	if s := alertSenderFromAPI(nil); s != nil {
		t.Errorf("alertSenderFromAPI(nil) = %v, want a true nil interface", s)
	}
	if s := alertSenderFromAPI(&TgAPI{}); s == nil {
		t.Error("alertSenderFromAPI(non-nil *TgAPI) returned a nil interface")
	}
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
		wantLivenessSnip string
	}{
		{name: "all probes OK", wantAlertCount: 0, wantLivenessSnip: "failures=0"},
		{name: "telegram fail triggers alert", telegramErr: os.ErrDeadlineExceeded, alertChatID: 42, wantAlertCount: 1, wantLivenessSnip: "failures=1"},
		{name: "gemini fail triggers alert", geminiErr: os.ErrDeadlineExceeded, alertChatID: 42, wantAlertCount: 1, wantLivenessSnip: "failures=1"},
		{name: "gmail ErrNotExist is not a failure", gmailErr: os.ErrNotExist, alertChatID: 42, wantAlertCount: 0, wantLivenessSnip: "failures=0"},
		{name: "gmail real error triggers alert", gmailErr: os.ErrPermission, alertChatID: 42, wantAlertCount: 1, wantLivenessSnip: "failures=1"},
		{name: "no alert chat ID suppresses message", telegramErr: os.ErrDeadlineExceeded, alertChatID: 0, wantAlertCount: 0, wantLivenessSnip: "failures=1"},
		{name: "multiple failures bundled in one alert", telegramErr: os.ErrDeadlineExceeded, geminiErr: os.ErrDeadlineExceeded, alertChatID: 99, wantAlertCount: 1, wantLivenessSnip: "failures=2"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			runHeartbeatSubtest(t, tc)
		})
	}
}

func runHeartbeatSubtest(t *testing.T, tc struct {
	name             string
	telegramErr      error
	geminiErr        error
	gmailErr         error
	alertChatID      int64
	wantAlertCount   int
	wantLivenessSnip string
}) {
	t.Helper()
	dir := t.TempDir()
	sender := &mockAlertSender{}
	hb := &HeartbeatRunner{
		probes: &doctor.Probes{
			ProbeTelegram: func(_ string) (string, error) { return "", tc.telegramErr },
			ProbeGemini:   func(_ string) error { return tc.geminiErr },
			ProbeGmail:    func(_ string) error { return tc.gmailErr },
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
}
