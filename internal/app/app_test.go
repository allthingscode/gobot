//nolint:testpackage // intentionally uses unexported helpers from main package
package app

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/dashboard"
	"github.com/allthingscode/gobot/internal/logattr"
	"github.com/allthingscode/gobot/internal/memory"
)

//nolint:paralleltest,gocognit,cyclop // serialized all-sink matrix captures global logger and stderr
func TestSetupLogging_AnyAllSinks(t *testing.T) {
	for _, format := range []string{"text", "json"} {
		for _, withHub := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/hub=%v", format, withHub), func(t *testing.T) {
				oldLogger, oldStderr := slog.Default(), os.Stderr
				reader, writer, err := os.Pipe()
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { slog.SetDefault(oldLogger); os.Stderr = oldStderr; _ = writer.Close(); _ = reader.Close() })
				os.Stderr = writer
				drained := make(chan string, 1)
				go func() { data, _ := io.ReadAll(reader); drained <- string(data) }()
				cfg := &config.Config{}
				cfg.Runtime.StorageRoot = tempLogRoot(t)
				cfg.Logging.Format = format
				var hub *dashboard.Hub
				var sub chan *dashboard.LogEntry
				if withHub {
					hub = dashboard.NewHub(10)
					defer hub.Close()
					sub, _ = hub.Subscribe()
				}
				SetupLogging(cfg, hub)
				slog.Default().WithGroup("request").With("bound", []string{"token=bound-marker"}).LogAttrs(context.Background(), slog.LevelInfo,
					"diagnostic", logattr.Err(fmt.Errorf("request failed: %w", errors.New("token=error-marker"))),
					slog.Any("args", []string{"first", "token=args-marker", "last"}),
					slog.Any("nested", map[string]any{"password": "map-marker", "detail": "token=nested-marker"}))
				os.Stderr = oldStderr
				if err := writer.Close(); err != nil {
					t.Fatal(err)
				}
				outputs := []string{<-drained, readLogFile(t, cfg)}
				if withHub {
					entry := <-sub
					encoded, err := json.Marshal(entry)
					if err != nil {
						t.Fatal(err)
					}
					outputs = append(outputs, string(encoded))
				}
				for _, output := range outputs {
					assertNoLogLeaks(t, output, "bound-marker", "error-marker", "args-marker", "map-marker", "nested-marker")
					for _, keep := range []string{"request failed", "first", "last", "[REDACTED]"} {
						if !strings.Contains(output, keep) {
							t.Fatalf("missing %q: %s", keep, output)
						}
					}
				}
			})
		}
	}
}

//nolint:paralleltest // uses global state // sets global logger
func TestSetupLogging(t *testing.T) {
	oldLogger := slog.Default()
	defer slog.SetDefault(oldLogger)

	tempDir, err := os.MkdirTemp("", "gobot-log-test-*")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}
	defer func() {
		_ = os.RemoveAll(tempDir) // ignore error as file may be locked
	}()

	cfg := &config.Config{}
	cfg.Runtime.StorageRoot = tempDir

	// Case 1: Text format
	SetupLogging(cfg, nil)
	slog.Info("test text log message")

	logFile := filepath.Join(tempDir, "logs", "gobot.log")
	if _, err := os.Stat(logFile); os.IsNotExist(err) {
		t.Errorf("expected log file %s to be created", logFile)
	}

	content, _ := os.ReadFile(logFile)
	if !strings.Contains(string(content), "test text log message") {
		t.Errorf("expected text log message in file, got: %s", string(content))
	}

	// Case 2: JSON format
	cfg.Logging.Format = "json"
	SetupLogging(cfg, nil)
	slog.Info("test json log message")

	content, _ = os.ReadFile(logFile)
	if !strings.Contains(string(content), "\"msg\":\"test json log message\"") {
		t.Errorf("expected json log message in file, got: %s", string(content))
	}
}

//nolint:paralleltest // uses global state // sets global logger
func TestSetupLogging_RedactsDurableLogsWithoutHub(t *testing.T) {
	oldLogger := slog.Default()
	t.Cleanup(func() { slog.SetDefault(oldLogger) })

	cfg := &config.Config{}
	cfg.Runtime.StorageRoot = tempLogRoot(t)

	SetupLogging(cfg, nil)
	slog.Info("gateway saw bearer sk-abcdefghij1234567890",
		"text", "https://api.example/send?token=deadbeefdeadbeef1234",
		"api_key", "stored-secret-value")

	content := readLogFile(t, cfg)
	assertNoLogLeaks(t, content,
		"sk-abcdefghij1234567890",
		"deadbeefdeadbeef1234",
		"stored-secret-value",
	)
}

//nolint:paralleltest // uses global state // sets global logger
func TestSetupLogging_RedactsDurableLogsAndHubEntriesWithHub(t *testing.T) {
	oldLogger := slog.Default()
	t.Cleanup(func() { slog.SetDefault(oldLogger) })

	cfg := &config.Config{}
	cfg.Runtime.StorageRoot = tempLogRoot(t)

	hub := dashboard.NewHub(10)
	t.Cleanup(hub.Close)
	sub, _ := hub.Subscribe()

	SetupLogging(cfg, hub)
	slog.Info("gateway saw bearer sk-abcdefghij1234567890",
		"text", "https://api.example/send?token=deadbeefdeadbeef1234",
		"api_key", "stored-secret-value")

	var entry *dashboard.LogEntry
	select {
	case entry = <-sub:
	default:
		t.Fatal("expected log entry in hub")
	}

	for _, leak := range []string{
		"sk-abcdefghij1234567890",
		"deadbeefdeadbeef1234",
		"stored-secret-value",
	} {
		if strings.Contains(entry.Message, leak) {
			t.Fatalf("hub message leaked %q: %q", leak, entry.Message)
		}
		if text, _ := entry.Fields["text"].(string); strings.Contains(text, leak) {
			t.Fatalf("hub text field leaked %q: %q", leak, text)
		}
	}
	if entry.Fields["api_key"] != "[REDACTED]" {
		t.Fatalf("hub api_key = %v, want [REDACTED]", entry.Fields["api_key"])
	}

	content := readLogFile(t, cfg)
	assertNoLogLeaks(t, content,
		"sk-abcdefghij1234567890",
		"deadbeefdeadbeef1234",
		"stored-secret-value",
	)
}

func readLogFile(t *testing.T, cfg *config.Config) string {
	t.Helper()
	content, err := os.ReadFile(cfg.LogPath("gobot.log"))
	if err != nil {
		t.Fatalf("read log file: %v", err)
	}
	return string(content)
}

func tempLogRoot(t *testing.T) string {
	t.Helper()
	tempDir, err := os.MkdirTemp("", "gobot-redacted-log-test-*")
	if err != nil {
		t.Fatalf("create temp log root: %v", err)
	}
	t.Cleanup(func() {
		_ = os.RemoveAll(tempDir) // Windows may keep lumberjack's file handle briefly.
	})
	return tempDir
}

func assertNoLogLeaks(t *testing.T, content string, leaks ...string) {
	t.Helper()
	for _, leak := range leaks {
		if strings.Contains(content, leak) {
			t.Fatalf("durable log leaked %q in %q", leak, content)
		}
	}
	if !strings.Contains(content, "[REDACTED]") {
		t.Fatalf("durable log = %q, want redacted spans", content)
	}
}

func TestValidateRunPrerequisites(t *testing.T) {
	cfg := &config.Config{}
	cfg.Runtime.StorageRoot = t.TempDir()
	t.Cleanup(func() { agentctx.EvictCheckpointManagerForTest(cfg.StorageRoot()) })

	// Case 1: Telegram disabled, no token needed
	cfg.Channels.Telegram.Enabled = false
	if err := validateRunPrerequisites(cfg); err != nil {
		t.Errorf("unexpected error: %v", err)
	}

	// Case 2: Telegram enabled, no token -> error
	cfg.Channels.Telegram.Enabled = true
	t.Setenv("TELEGRAM_BOT_TOKEN", "")
	err := validateRunPrerequisites(cfg)
	if err == nil {
		t.Error("expected error for missing token")
	} else {
		errText := err.Error()
		if !strings.Contains(errText, "TELEGRAM_BOT_TOKEN") {
			t.Errorf("expected error to mention TELEGRAM_BOT_TOKEN, got %q", errText)
		}
		if strings.Contains(errText, "TELEGRAM_APITOKEN") {
			t.Errorf("expected error not to mention TELEGRAM_APITOKEN, got %q", errText)
		}
	}

	// Case 3: Telegram enabled, token set -> ok
	cfg.Channels.Telegram.Token = "test-token"
	if err := validateRunPrerequisites(cfg); err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestSetupConsolidator(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	stack := &AgentStack{
		MemStore: &memory.MemoryStore{},
	}
	mgr := &agent.SessionManager{}
	handler := &DispatchHandler{}

	SetupConsolidator(cfg, stack, mgr, handler, nil, nil)
	if handler.Consolidator == nil {
		t.Error("SetupConsolidator failed to set handler.Consolidator")
	}
}

func TestSetupGateHandler(t *testing.T) {
	t.Parallel()
	handler := &DispatchHandler{}

	// Case 1: nil store
	got := SetupGateHandler(nil, handler)
	if got != handler {
		t.Error("expected original handler for nil store")
	}
}

func TestInitIdempotency(t *testing.T) {
	t.Parallel()
	// Just ensure it doesn't panic with nil store
	InitIdempotency(context.Background(), &config.Config{}, &AgentRunner{}, nil, nil)
}

func TestLiveProbes(t *testing.T) {
	t.Parallel()
	p := LiveProbes()
	if p == nil {
		t.Error("LiveProbes returned nil")
	}
}

func TestSetupHooks(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	runner := &AgentRunner{}
	mgr := &agent.SessionManager{}

	h, hitl, setupErr := SetupHooks(cfg, runner, mgr, nil, nil)
	if setupErr != nil {
		t.Fatalf("SetupHooks: %v", setupErr)
	}
	if h == nil || hitl == nil {
		t.Error("SetupHooks returned nil")
	}
}

func TestRunAgentLoop(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithCancel(context.Background())
	// Cancel immediately to test the loop exit
	cancel()

	cfg := &config.Config{}
	cfg.Runtime.StorageRoot = t.TempDir()
	t.Cleanup(func() { agentctx.EvictCheckpointManagerForTest(cfg.StorageRoot()) })
	stack := &AgentStack{Runner: &AgentRunner{}}

	if err := runAgentLoop(ctx, cfg, stack, nil, nil, nil, nil, time.Now()); err != nil {
		t.Fatal(err)
	}
}

func TestInitIdempotencyHandlesTypedNilCheckpointManager(t *testing.T) {
	t.Parallel()

	var checkpoints *agentctx.CheckpointManager
	var store agent.CheckpointStore = checkpoints

	InitIdempotency(context.Background(), &config.Config{}, &AgentRunner{}, store, &sync.WaitGroup{})
}

func TestRunPreFlightDiagnostics(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	runPreFlightDiagnostics(cfg)
}

func TestReconcileWhitelistParsing(t *testing.T) {
	t.Parallel()
	for _, tt := range []struct {
		name string
		ids  []string
		want int
	}{
		{"nil", nil, 0}, {"empty", []string{}, 0},
		{"invalid", []string{"", "abc", "0", "+0", "-0", " 123", "9223372036854775808", "-9223372036854775809"}, 0},
		{"mixed signed duplicates", []string{"abc", "0", "123", "+123", "00123", "-100123"}, 2},
	} {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			cm, pairing := newWhitelistReconciliationStore(t)
			cfg := &config.Config{}
			cfg.Channels.Telegram.AllowFrom = tt.ids
			if got := ReconcileAuthorizedFromAllowFrom(cfg, cm); got != tt.want {
				t.Fatalf("reconciled=%d want=%d", got, tt.want)
			}
			if got := ReconcileAuthorizedFromAllowFrom(cfg, cm); got != 0 {
				t.Fatalf("repeat reconciled=%d", got)
			}
			assertReconciledWhitelist(t, pairing, tt.want == 2)
		})
	}
}

func assertReconciledWhitelist(t *testing.T, pairing *agentctx.PairingStore, mixed bool) {
	t.Helper()
	for _, id := range []int64{0, 123, -100123, 999} {
		got, err := pairing.IsAuthorized(id)
		want := id == 999 || (mixed && (id == 123 || id == -100123))
		if err != nil || got != want {
			t.Fatalf("authorized(%d)=%t,%v want=%t", id, got, err, want)
		}
	}
}

func newWhitelistReconciliationStore(t *testing.T) (*agentctx.CheckpointManager, *agentctx.PairingStore) {
	t.Helper()
	cm, err := agentctx.GetCheckpointManager(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cm.DB().Close() })
	pairing, err := agentctx.NewPairingStore(cm.DB())
	if err != nil {
		t.Fatal(err)
	}
	if err := pairing.AuthorizeByChatID(999, "operator"); err != nil {
		t.Fatal(err)
	}
	return cm, pairing
}

type telegramStartupCase struct {
	name     string
	enabled  bool
	local    bool
	failure  bool
	nilAPI   bool
	existing bool
}

//nolint:paralleltest // captures process stdout and the default structured logger
func TestRunAgentLoopTelegramConstruction(t *testing.T) {
	for _, tc := range []telegramStartupCase{
		{name: "malformed token", enabled: true, local: true, failure: true},
		{name: "simulated GetMe failure fresh", enabled: true, failure: true},
		{name: "simulated GetMe failure preserves marker", enabled: true, failure: true, existing: true},
		{name: "nil adapter", enabled: true, nilAPI: true, failure: true},
		{name: "enabled success", enabled: true},
		{name: "disabled invalid token"},
	} {
		t.Run(tc.name, func(t *testing.T) { testTelegramStartupCase(t, tc) })
	}
}

func testTelegramStartupCase(t *testing.T, tc telegramStartupCase) {
	t.Helper()
	cfg := &config.Config{}
	cfg.Runtime.StorageRoot = t.TempDir()
	t.Cleanup(func() { agentctx.EvictCheckpointManagerForTest(cfg.StorageRoot()) })
	cfg.Channels.Telegram.Enabled = tc.enabled
	cfg.Channels.Telegram.Token = "synthetic-invalid-secret"
	if tc.enabled {
		cfg.Channels.Telegram.AllowFrom = []string{"123"}
	}
	marker := startupMarkerPath(cfg.StorageRoot())
	previous := []byte("historical startup marker\n")
	if tc.existing {
		if err := os.MkdirAll(filepath.Dir(marker), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(marker, previous, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	var logs bytes.Buffer
	oldLogger := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&logs, nil)))
	t.Cleanup(func() { slog.SetDefault(oldLogger) })
	output := captureTelegramStartupOutput(t)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	var stack *AgentStack
	var api *TgAPI
	if !tc.failure {
		stack = &AgentStack{Runner: &AgentRunner{}}
		if tc.enabled {
			api, _ = newPollingAPI(t)
			api.username = "fixture_bot"
		}
		// Explicit cancellation permits a bounded full-loop completion without network.
		cancel()
	} else {
		// These would require runtime setup if the constructor failure were ignored.
		cfg.Gateway.Enabled = true
		cfg.Gateway.WebAddr = "127.0.0.1:0"
		cfg.Cron.Enabled = true
		cfg.Heartbeat.Enabled = true
	}
	calls := 0
	raw := "telego GetMe: https://api.telegram.org/bot" + cfg.Channels.Telegram.Token + "/getMe response-body-sensitive"
	factory := telegramStartupFactory(t, tc, cfg, api, raw, &calls)
	err := runAgentLoopWithTelegram(ctx, cfg, stack, nil, nil, nil, nil, time.Now(), factory)
	stdout := output()
	wantCalls := 0
	if tc.enabled {
		wantCalls = 1
	}
	if calls != wantCalls {
		t.Fatalf("constructor calls=%d want=%d", calls, wantCalls)
	}
	assertTelegramStartupResult(t, tc, cfg, err, stdout, logs.String(), raw, previous)
}

func assertTelegramStartupResult(t *testing.T, tc telegramStartupCase, cfg *config.Config, err error, stdout, logs, raw string, previous []byte) {
	t.Helper()
	content, markerErr := os.ReadFile(startupMarkerPath(cfg.StorageRoot()))
	if tc.failure {
		assertTelegramStartupFailure(t, tc, cfg, err, stdout, logs, raw, previous, content, markerErr)
		return
	}
	if err != nil {
		t.Fatal(err)
	}
	if markerErr != nil {
		t.Fatalf("success marker: %v", markerErr)
	}
	assertTelegramSuccessOutput(t, tc.enabled, stdout, logs)
}

func assertTelegramStartupFailure(t *testing.T, tc telegramStartupCase, cfg *config.Config, err error, stdout, logs, raw string, previous, content []byte, markerErr error) {
	t.Helper()
	if err == nil {
		t.Fatal("expected startup failure")
	}
	if !strings.Contains(err.Error(), "telegram initialization") || !strings.Contains(err.Error(), "credentials and connectivity") {
		t.Fatalf("unsafe or unhelpful error: %v", err)
	}
	assertTelegramStartupSafe(t, err, stdout, logs, cfg.Channels.Telegram.Token, raw)
	if stdout != "" || strings.Contains(logs, "startup ready") || strings.Contains(logs, "started") {
		t.Fatalf("failure emitted startup success: %s %s", stdout, logs)
	}
	assertTelegramFailureStorage(t, tc, cfg, previous, content, markerErr)
}

func assertTelegramStartupSafe(t *testing.T, err error, stdout, logs, token, raw string) {
	t.Helper()
	for current := err; current != nil; current = errors.Unwrap(current) {
		for _, sensitive := range []string{token, raw, "https://api.telegram.org", "response-body-sensitive"} {
			if strings.Contains(current.Error()+stdout+logs, sensitive) {
				t.Fatalf("startup leaked %q", sensitive)
			}
		}
	}
}

func captureTelegramStartupOutput(t *testing.T) func() string {
	t.Helper()
	file, err := os.CreateTemp(t.TempDir(), "stdout")
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdout
	os.Stdout = file
	t.Cleanup(func() { os.Stdout = old; _ = file.Close() })
	return func() string {
		os.Stdout = old
		if _, err := file.Seek(0, 0); err != nil {
			t.Fatal(err)
		}
		data, err := io.ReadAll(file)
		if err != nil {
			t.Fatal(err)
		}
		return string(data)
	}
}

func telegramStartupFactory(t *testing.T, tc telegramStartupCase, cfg *config.Config, api *TgAPI, raw string, calls *int) func(string, []string, *config.Config) (*TgAPI, error) {
	t.Helper()
	return func(token string, allow []string, gotCfg *config.Config) (*TgAPI, error) {
		(*calls)++
		if token != cfg.TelegramToken() || !reflect.DeepEqual(allow, cfg.TelegramAllowedFrom()) || gotCfg != cfg {
			t.Fatal("constructor arguments changed")
		}
		if tc.local {
			return NewTgAPI(token, allow, gotCfg)
		}
		if tc.nilAPI {
			return nil, nil
		}
		if tc.failure {
			return nil, errors.New(raw)
		}
		return api, nil
	}
}

func assertTelegramFailureStorage(t *testing.T, tc telegramStartupCase, cfg *config.Config, previous, content []byte, markerErr error) {
	t.Helper()
	if tc.existing {
		if markerErr != nil || !bytes.Equal(content, previous) {
			t.Fatalf("existing marker changed: %q, %v", content, markerErr)
		}
	} else if !errors.Is(markerErr, os.ErrNotExist) {
		t.Fatalf("fresh marker exists: %v", markerErr)
	}
	entries, readErr := os.ReadDir(cfg.StorageRoot())
	if readErr != nil {
		t.Fatal(readErr)
	}
	if !tc.existing && len(entries) != 0 {
		t.Fatalf("failure created runtime storage: %v", entries)
	}
}

func assertTelegramSuccessOutput(t *testing.T, enabled bool, stdout, logs string) {
	t.Helper()
	label := startupDisabled
	if enabled {
		label = "@fixture_bot"
	}
	if !strings.Contains(stdout, "gobot ready") || !strings.Contains(stdout, label) || !strings.Contains(logs, "startup ready") {
		t.Fatalf("missing startup success: %s %s", stdout, logs)
	}
	if enabled && !strings.Contains(logs, "telegram bot started") {
		t.Fatal("enabled adapter did not reach bot startup")
	}
	if strings.Contains(logs, "drain timed out") {
		t.Fatal("shutdown was not bounded cleanly")
	}
}
