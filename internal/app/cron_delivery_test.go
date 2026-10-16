//nolint:testpackage,paralleltest // exercises internal contracts and serial shared HTTP/log fixtures
package app

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/cron"
	"github.com/allthingscode/gobot/internal/integrations/google"
	"github.com/allthingscode/gobot/internal/provider"
	"github.com/allthingscode/gobot/internal/reporter"
)

const (
	deliveryMissing   = "missing"
	deliveryExpired   = "expired"
	deliveryEmpty     = "empty"
	deliveryFallback  = "fallback"
	deliveryForbidden = "forbidden"
	deliveryAbsent    = "absent"
	deliveryAlert     = "alert"
	deliverySuccess   = "success"
)

type deliveryAPI struct {
	mockAPI
	err error
}

func (a *deliveryAPI) Send(ctx context.Context, msg bot.OutboundMessage) error {
	_ = a.mockAPI.Send(ctx, msg)
	return a.err
}

type deliveryProvider struct {
	mockChatProvider
	calls int
}

func (p *deliveryProvider) Chat(ctx context.Context, r provider.ChatRequest) (*provider.ChatResponse, error) {
	p.calls++
	return p.mockChatProvider.Chat(ctx, r)
}
func deliveryDispatcher(t *testing.T, response string) (*CronDispatcher, *deliveryProvider, *deliveryAPI) {
	t.Helper()
	cfg := &config.Config{}
	cfg.Agents.Specialists = map[string]config.SpecialistConfig{"researcher": {Provider: mockName, Model: "test"}}
	prov := &deliveryProvider{mockChatProvider: mockChatProvider{resp: response}}
	registry := provider.NewRegistry()
	if err := registry.Register(prov); err != nil {
		t.Fatal(err)
	}
	api := &deliveryAPI{}
	runner := NewAgentRunner(prov, "test", "test", cfg)
	cd := NewCronDispatcher(cfg, agent.NewSessionManager(runner, nil, "test"), &AgentStack{Providers: registry}, bot.New(api, nil), reporter.NewTemplateManager(""))
	cd.secretsRoot = t.TempDir()
	return cd, prov, api
}

//nolint:gocognit,cyclop // Keep each delivery contract matrix and its assertions together.
func TestCronDeliveryTelegram(t *testing.T) {
	cause := errors.New("transport unavailable")
	for _, specialist := range []bool{false, true} {
		for _, tc := range []struct {
			name, to, response string
			silent             bool
			sendErr            error
			wantErr            string
			sends              int
		}{
			{name: "chat thread", to: "telegram:123:7", response: "answer", sends: 1},
			{name: "transport", to: "telegram:123:7", response: "answer", sendErr: cause, wantErr: "send cron telegram", sends: 1},
			{name: "target", to: "telegram:bad", response: "answer", wantErr: "parse cron telegram"},
			{name: deliveryEmpty, to: "telegram:123:7"},
			{name: "silent", to: "telegram:123:7", response: "answer", silent: true},
			{name: deliveryAbsent, response: "answer"},
		} {
			t.Run(fmt.Sprintf("%t/%s", specialist, tc.name), func(t *testing.T) {
				cd, prov, api := deliveryDispatcher(t, tc.response)
				api.err = tc.sendErr
				p := cron.Payload{ID: "delivery", Channel: chanTelegram, To: tc.to, Message: "generate"}
				if specialist {
					p.Agent = "researcher"
				}
				var err error
				if tc.silent {
					if specialist {
						err = cd.dispatchSpecialist(context.Background(), p, chanTelegram, tc.to, true)
					} else {
						err = cd.dispatchSilent(context.Background(), p, tc.to)
					}
				} else {
					err = cd.Dispatch(context.Background(), p)
				}
				assertDeliveryError(t, err, tc.wantErr)
				if tc.sendErr != nil && !errors.Is(err, cause) {
					t.Fatalf("lost cause: %v", err)
				}
				if tc.name == "target" {
					var num *strconv.NumError
					if !errors.As(err, &num) {
						t.Fatalf("lost parse cause: %v", err)
					}
				}
				if len(api.sent) != tc.sends {
					t.Fatalf("sends=%d want=%d", len(api.sent), tc.sends)
				}
				if tc.sends > 0 && (api.sent[0].ChatID != 123 || api.sent[0].ThreadID != 7) {
					t.Fatal("lost chat/thread routing")
				}
				wantCalls := 1
				if !specialist && tc.to == "" {
					wantCalls = 0
				}
				if prov.calls != wantCalls {
					t.Fatalf("generation calls=%d want=%d", prov.calls, wantCalls)
				}
			})
		}
	}
}
func assertDeliveryError(t *testing.T, err error, want string) {
	t.Helper()
	if want == "" {
		if err != nil {
			t.Fatal(err)
		}
		return
	}
	if err == nil || !strings.Contains(err.Error(), want) {
		t.Fatalf("error=%v want context %q", err, want)
	}
	var notified *cron.AlreadyNotifiedError
	if errors.As(err, &notified) {
		t.Fatalf("delivery incorrectly marked notified: %v", err)
	}
}

type deliveryTransport func(*http.Request) (*http.Response, error)

func (f deliveryTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func deliveryToken(t *testing.T, root, mode string) {
	t.Helper()
	if mode == deliveryMissing {
		return
	}
	expiry := time.Now().Add(time.Hour)
	if mode == deliveryExpired {
		expiry = time.Now().Add(-time.Hour)
	}
	data, err := json.Marshal(map[string]any{"token": "synthetic", "expiry": expiry})
	if err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(root, "gmail")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "token.json"), data, 0o600); err != nil {
		t.Fatal(err)
	}
}

func installDeliveryTransport(t *testing.T, mode string, calls *int) {
	t.Helper()
	old := google.TimeoutClient
	google.TimeoutClient = &http.Client{Transport: deliveryTransport(func(r *http.Request) (*http.Response, error) {
		*calls++
		var payload struct {
			Raw string `json:"raw"`
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		raw, err := base64.URLEncoding.DecodeString(payload.Raw)
		if err != nil {
			t.Fatal(err)
		}
		recipient := "explicit@example.com"
		if mode == deliveryFallback {
			recipient = "fallback@example.com"
		}
		if !strings.Contains(string(raw), "To: "+recipient) {
			t.Fatalf("recipient lost: %s", raw)
		}
		code := http.StatusOK
		if mode == deliveryForbidden {
			code = http.StatusForbidden
		}
		return &http.Response{StatusCode: code, Body: io.NopCloser(strings.NewReader(`{"id":"sent"}`)), Header: make(http.Header)}, nil
	})}
	t.Cleanup(func() { google.TimeoutClient = old })
}

//nolint:gocognit,cyclop // Keep each delivery contract matrix and its assertions together.
func TestCronDeliveryEmail(t *testing.T) {
	for _, kind := range []string{"normal", "specialist", deliveryAlert} {
		for _, mode := range []string{deliveryMissing, deliveryExpired, deliveryForbidden, deliverySuccess, deliveryFallback, deliveryAbsent, deliveryEmpty} {
			t.Run(kind+"/"+mode, func(t *testing.T) {
				cd, prov, _ := deliveryDispatcher(t, "answer")
				if mode == deliveryEmpty {
					prov.resp = ""
				}
				cd.userEmail = "fallback@example.com"
				deliveryToken(t, cd.secretsRoot, mode)
				calls := 0
				installDeliveryTransport(t, mode, &calls)
				p := cron.Payload{ID: "delivery", Channel: chanEmail, To: "explicit@example.com", Message: "generate"}
				if mode == deliveryFallback || mode == deliveryAbsent {
					p.To = ""
				}
				if mode == deliveryAbsent {
					cd.userEmail = ""
				}
				if kind == "specialist" {
					p.Agent = "researcher"
				}
				var err error
				if kind == deliveryAlert {
					err = cd.Alert(context.Background(), p)
				} else {
					err = cd.Dispatch(context.Background(), p)
				}
				want := ""
				if mode == deliveryMissing || mode == deliveryExpired {
					want = "initialize cron email"
				}
				if mode == deliveryForbidden {
					want = "send cron email"
				}
				assertDeliveryError(t, err, want)
				if mode == deliveryExpired && !errors.Is(err, google.ErrNeedsReauth) {
					t.Fatalf("lost auth cause: %v", err)
				}
				if mode == deliveryMissing && !errors.Is(err, os.ErrNotExist) {
					t.Fatalf("lost missing token cause: %v", err)
				}
				wantSends := 0
				if mode == deliveryForbidden || mode == deliverySuccess || mode == deliveryFallback || (mode == deliveryEmpty && kind == deliveryAlert) {
					wantSends = 1
				}
				if calls != wantSends {
					t.Fatalf("HTTP calls=%d want=%d", calls, wantSends)
				}
				wantGenerations := 1
				if kind == deliveryAlert || (mode == deliveryAbsent && kind == "normal") {
					wantGenerations = 0
				}
				if prov.calls != wantGenerations {
					t.Fatalf("generation calls=%d want=%d", prov.calls, wantGenerations)
				}
			})
		}
	}
}

//nolint:gocognit,cyclop // Keep each delivery contract matrix and its assertions together.
func TestBriefingRetryDeliveryOutcome(t *testing.T) {
	for _, mode := range []string{deliveryMissing, deliverySuccess, deliveryEmpty} {
		t.Run(mode, func(t *testing.T) {
			cd, _, _ := deliveryDispatcher(t, "")
			deliveryToken(t, cd.secretsRoot, mode)
			old := google.TimeoutClient
			google.TimeoutClient = &http.Client{Transport: deliveryTransport(func(_ *http.Request) (*http.Response, error) {
				return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{}`)), Header: make(http.Header)}, nil
			})}
			t.Cleanup(func() { google.TimeoutClient = old })
			var logs bytes.Buffer
			logger := slog.Default()
			slog.SetDefault(slog.New(slog.NewTextHandler(&logs, nil)))
			t.Cleanup(func() { slog.SetDefault(logger) })
			generations, statuses := 0, 0
			cd.dispatchHook = func(_ context.Context, _, _ string) (string, error) {
				generations++
				if mode == deliveryEmpty {
					return "", nil
				}
				return "answer", nil
			}
			cd.guardHook = func(_, _ string) error { return nil }
			cd.failureEmailHook = func(_ context.Context, _ cron.Payload, _, body string) {
				statuses++
				if !strings.Contains(body, "initialize cron email") {
					t.Fatal(body)
				}
			}
			cd.retryMorningBriefing(make(chan struct{}), cron.Payload{ID: morningBriefingJobID}, "user@example.com", []time.Duration{0, 0})
			if generations != 1 {
				t.Fatalf("generations=%d", generations)
			}
			wantStatuses := 0
			if mode == deliveryMissing {
				wantStatuses = 1
			}
			if statuses != wantStatuses {
				t.Fatalf("statuses=%d", statuses)
			}
			if strings.Contains(logs.String(), "email delivered") != (mode == deliverySuccess) {
				t.Fatalf("incorrect delivery status: %s", logs.String())
			}
		})
	}
}

func TestMorningBriefingInitialDeliveryFailure(t *testing.T) {
	cd, prov, _ := deliveryDispatcher(t, "[Sources: https://example.com] Published: 2026-10-16")
	cd.storageRoot = t.TempDir()
	dir := filepath.Join(cd.storageRoot, "workspace", "sessions", "2026-10-16")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(dir, sanitizeSessionKeyForFile(testMorningBriefingEmailSession)+"_20261016T130000Z.md")
	if err := os.WriteFile(file, []byte("tool_call: search_ai"), 0o600); err != nil {
		t.Fatal(err)
	}
	statuses := 0
	cd.failureEmailHook = func(_ context.Context, _ cron.Payload, _, _ string) { statuses++ }
	err := cd.Dispatch(context.Background(), cron.Payload{ID: morningBriefingJobID, Channel: chanEmail, To: "user@example.com", Message: "generate"})
	assertDeliveryError(t, err, "initialize cron email")
	if prov.calls != 1 || statuses != 0 {
		t.Fatalf("generations=%d failure notifications=%d", prov.calls, statuses)
	}
}
