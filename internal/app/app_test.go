//nolint:testpackage // intentionally uses unexported helpers from main package
package app

import (
	"context"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/dashboard"
	"github.com/allthingscode/gobot/internal/memory"
)

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
	stack := &AgentStack{Runner: &AgentRunner{}}

	_ = runAgentLoop(ctx, cfg, stack, nil, nil, nil, nil, time.Now())
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
