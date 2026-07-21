//nolint:testpackage // intentionally covers unexported CLI helpers
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/secrets"
	"github.com/allthingscode/gobot/internal/state"
	"github.com/spf13/cobra"
)

//nolint:paralleltest // uses global env/config
func TestRunFormatCheck(t *testing.T) {
	tempDir := setupTestHome(t)
	path := filepath.Join(tempDir, ".gobot", "config.json")
	cfg := &config.Config{}
	cfg.Runtime.StorageRoot = tempDir
	if err := cfg.Save(path); err != nil {
		t.Fatalf("Save: %v", err)
	}

	if err := runFormatCheck(path, cfg); err != nil {
		t.Fatalf("runFormatCheck formatted file: %v", err)
	}

	if err := os.WriteFile(path, []byte(`{"strategic_edition":{"storage_root":"x"}}`), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}
	err := runFormatCheck(path, cfg)
	if err == nil || !strings.Contains(err.Error(), "not correctly formatted") {
		t.Fatalf("expected formatting error, got %v", err)
	}

	err = runFormatCheck(filepath.Join(tempDir, "missing.json"), cfg)
	if err == nil || !strings.Contains(err.Error(), "does not exist") {
		t.Fatalf("expected missing file error, got %v", err)
	}
}

//nolint:paralleltest // uses global env/config
func TestCmdConfigStorageRoot_PrintsResolvedRoot(t *testing.T) {
	tempDir := setupTestHome(t)
	cfg := &config.Config{}
	cfg.Runtime.StorageRoot = tempDir
	if err := os.MkdirAll(filepath.Join(tempDir, ".gobot"), 0o755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	if err := cfg.Save(filepath.Join(tempDir, ".gobot", "config.json")); err != nil {
		t.Fatalf("Save: %v", err)
	}

	cmd := cmdConfigStorageRoot()
	out := bytes.NewBuffer(nil)
	cmd.SetOut(out)
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}
	if got := strings.TrimSpace(out.String()); got != tempDir {
		t.Fatalf("storage root = %q, want %q", got, tempDir)
	}
}

//nolint:cyclop // Table exercises several log parsing/filter combinations in one fixture.
func TestLogParsingAndFilteringHelpers(t *testing.T) {
	t.Parallel()

	if _, err := parseSinceDuration("not-a-duration"); err == nil {
		t.Fatal("expected invalid duration error")
	}
	since, err := parseSinceDuration("1h")
	if err != nil {
		t.Fatalf("parseSinceDuration: %v", err)
	}
	if since.IsZero() || time.Since(since) < 59*time.Minute {
		t.Fatalf("unexpected since time: %v", since)
	}

	valid := "time=2026-07-02T14:00:00Z level=ERROR msg=boom"
	parsed, ok := parseLogTime(valid)
	if !ok || parsed.Format(time.RFC3339) != "2026-07-02T14:00:00Z" {
		t.Fatalf("parseLogTime valid = %v, %v", parsed, ok)
	}
	if _, ok := parseLogTime("level=INFO msg=no-time"); !ok {
		t.Fatal("lines without time should be accepted")
	}
	if _, ok := parseLogTime("time=2026-07-02T14:00:00Z"); !ok {
		t.Fatal("lines without a suffix after time should be accepted")
	}
	if _, ok := parseLogTime("time=bad level=INFO msg=nope"); ok {
		t.Fatal("invalid timestamp should be rejected")
	}

	filter := makeLogFilter("ERROR", time.Date(2026, 7, 2, 13, 0, 0, 0, time.UTC))
	if !filter(valid) {
		t.Fatal("expected matching error line after since time")
	}
	if filter("time=2026-07-02T12:00:00Z level=ERROR msg=old") {
		t.Fatal("expected old line to be filtered")
	}
	if filter("time=2026-07-02T14:00:00Z level=INFO msg=info") {
		t.Fatal("expected non-error line to be filtered")
	}
}

func TestRunLogsList_PrintsOnlyGobotLogs(t *testing.T) {
	t.Parallel()

	logsDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(logsDir, "gobot-a.log"), []byte("a"), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}
	if err := os.WriteFile(filepath.Join(logsDir, "other.log"), []byte("b"), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	cmd := &cobra.Command{}
	out := bytes.NewBuffer(nil)
	cmd.SetOut(out)
	if err := runLogsList(cmd, logsDir); err != nil {
		t.Fatalf("runLogsList: %v", err)
	}
	got := out.String()
	if !strings.Contains(got, "Available log files:") || !strings.Contains(got, "gobot-a.log") {
		t.Fatalf("expected gobot log listing, got %q", got)
	}
	if strings.Contains(got, "other.log") {
		t.Fatalf("non-gobot log should not be listed: %q", got)
	}
}

//nolint:paralleltest // uses global env/config
func TestRunLogs_ExplicitFileWithSinceAndFilter(t *testing.T) {
	tempDir := setupTestHome(t)
	logFile := filepath.Join(tempDir, "selected.log")
	content := strings.Join([]string{
		"time=2026-07-02T13:00:00Z level=ERROR msg=old",
		"time=2026-07-02T15:00:00Z level=INFO msg=wrong-level",
		"time=2026-07-02T15:00:00Z level=ERROR msg=kept",
		"",
	}, "\n")
	if err := os.WriteFile(logFile, []byte(content), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	cmd := &cobra.Command{}
	out := bytes.NewBuffer(nil)
	cmd.SetOut(out)
	if err := runLogs(cmd, logFile, 10, "error", "1000000h", false); err != nil {
		t.Fatalf("runLogs: %v", err)
	}
	got := out.String()
	if !strings.Contains(got, "msg=kept") || !strings.Contains(got, "msg=old") {
		t.Fatalf("expected error lines, got %q", got)
	}
	if strings.Contains(got, "wrong-level") {
		t.Fatalf("info line should have been filtered: %q", got)
	}
}

func TestFollowLogsContextCancellation(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	cmd := &cobra.Command{}
	cmd.SetContext(ctx)
	reader := bufio.NewReader(strings.NewReader(""))
	err := followLogs(cmd, reader, "", func(string) bool { return true })
	if err == nil || !strings.Contains(err.Error(), "context done") {
		t.Fatalf("expected context done error, got %v", err)
	}
}

//nolint:paralleltest // uses global env/config
func TestCmdSecretsListAndDelete(t *testing.T) {
	tempDir := setupTestHome(t)
	store := secrets.NewSecretsStore(tempDir)
	if err := store.Set("alpha", "one"); err != nil {
		t.Fatalf("Set alpha: %v", err)
	}
	if err := store.Set("beta", "two"); err != nil {
		t.Fatalf("Set beta: %v", err)
	}

	out := captureStdout(t, func() {
		cmd := cmdSecretsList()
		if err := cmd.Execute(); err != nil {
			t.Fatalf("list Execute: %v", err)
		}
	})
	if !strings.Contains(out, "alpha") || !strings.Contains(out, "beta") {
		t.Fatalf("expected secret keys in output, got %q", out)
	}

	out = captureStdout(t, func() {
		cmd := cmdSecretsDelete()
		cmd.SetArgs([]string{"alpha"})
		if err := cmd.Execute(); err != nil {
			t.Fatalf("delete Execute: %v", err)
		}
	})
	if !strings.Contains(out, `Secret "alpha" deleted.`) {
		t.Fatalf("expected delete confirmation, got %q", out)
	}
	if got, err := store.Get("alpha"); err != nil || got != "" {
		t.Fatalf("deleted secret = %q, err %v", got, err)
	}
}

//nolint:paralleltest // uses global env/config
func TestCmdStateListAndInspectActiveWorkflow(t *testing.T) {
	tempDir := setupTestHome(t)
	stateDir := filepath.Join(tempDir, "state")
	manager := state.NewManager(state.ManagerConfig{StateDir: stateDir, LockTimeout: time.Second, MaxRetries: 1})
	if err := manager.Init(); err != nil {
		t.Fatalf("Init: %v", err)
	}
	data, err := json.Marshal(map[string]string{"task": "demo"})
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	if _, err := manager.CreateWorkflow("wf-1", data); err != nil {
		t.Fatalf("CreateWorkflow: %v", err)
	}

	listOut := captureStdout(t, func() {
		cmd := cmdStateList()
		if err := cmd.Execute(); err != nil {
			t.Fatalf("list Execute: %v", err)
		}
	})
	if !strings.Contains(listOut, "wf-1") || !strings.Contains(listOut, "pending") {
		t.Fatalf("expected workflow in list output, got %q", listOut)
	}

	inspectOut := captureStdout(t, func() {
		cmd := cmdStateInspect()
		cmd.SetArgs([]string{"wf-1"})
		if err := cmd.Execute(); err != nil {
			t.Fatalf("inspect Execute: %v", err)
		}
	})
	if !strings.Contains(inspectOut, "Workflow ID:    wf-1") || !strings.Contains(inspectOut, `"task": "demo"`) {
		t.Fatalf("expected workflow details, got %q", inspectOut)
	}
}

//nolint:paralleltest // uses global env/config and cached checkpoint handles
func TestCmdCheckpointsListsMultipleResumableSessions(t *testing.T) {
	tempDir := setupTestHome(t)
	writeTestConfig(t, tempDir)

	manager, err := agentctx.GetCheckpointManager(tempDir)
	if err != nil {
		t.Fatalf("GetCheckpointManager: %v", err)
	}
	t.Cleanup(func() { agentctx.EvictCheckpointManagerForTest(tempDir) })

	saveCheckpointFixture(t, manager, "thread-alpha", "gemini-3-flash", 2, []string{"alpha prompt", "alpha reply"})
	saveCheckpointFixture(t, manager, "thread-beta", "gemini-3-pro", 7, []string{"beta prompt", "beta reply"})

	out := captureStdout(t, func() {
		cmd := cmdCheckpoints()
		if err := cmd.Execute(); err != nil {
			t.Fatalf("Execute: %v", err)
		}
	})

	for _, want := range []string{
		"THREAD ID", "LAST ACTIVE", "ITERATION", "MODEL",
		"thread-alpha", "thread-beta",
		"gemini-3-flash", "gemini-3-pro",
		"2", "7",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("expected checkpoint list output to contain %q, got %q", want, out)
		}
	}
}

//nolint:paralleltest // uses global env/config and cached checkpoint handles
func TestCmdResumePrintsTruncatedTailPreview(t *testing.T) {
	tempDir := setupTestHome(t)
	writeTestConfig(t, tempDir)

	manager, err := agentctx.GetCheckpointManager(tempDir)
	if err != nil {
		t.Fatalf("GetCheckpointManager: %v", err)
	}
	t.Cleanup(func() { agentctx.EvictCheckpointManagerForTest(tempDir) })

	messages := []string{
		"message-01 outside preview",
		"message-02 outside preview",
		"message-03 tail start",
		"message-04 tail",
		"message-05 tail",
		"message-06 tail",
		"message-07 tail",
		"message-08 tail end",
	}
	saveCheckpointFixture(t, manager, "thread-resume", "gemini-3-flash", 8, messages)

	out := captureStdout(t, func() {
		cmd := cmdResume()
		cmd.SetArgs([]string{"thread-resume"})
		if err := cmd.Execute(); err != nil {
			t.Fatalf("Execute: %v", err)
		}
	})

	for _, want := range []string{
		"Thread:    thread-resume",
		"Model:     gemini-3-flash",
		"Iteration: 8",
		"Messages:  8 total",
		"... (showing last 6 messages)",
		"message-03 tail start",
		"message-08 tail end",
		"session key: thread-resume",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("expected resume output to contain %q, got %q", want, out)
		}
	}
	if strings.Contains(out, "message-01 outside preview") || strings.Contains(out, "message-02 outside preview") {
		t.Fatalf("resume output included messages outside preview window: %q", out)
	}
}

//nolint:paralleltest // uses global env/config
func TestCmdStateRecoverReportsRecoveredRunningWorkflow(t *testing.T) {
	tempDir := setupTestHome(t)
	writeTestConfig(t, tempDir)

	manager := state.NewManager(state.ManagerConfig{
		StateDir:    filepath.Join(tempDir, "state"),
		LockTimeout: time.Second,
		MaxRetries:  1,
	})
	if err := manager.Init(); err != nil {
		t.Fatalf("Init: %v", err)
	}
	if _, err := manager.CreateWorkflow("wf-recover-cli", json.RawMessage(`{"step": "running"}`)); err != nil {
		t.Fatalf("CreateWorkflow: %v", err)
	}
	if err := manager.UpdateStatus("wf-recover-cli", state.StatusRunning); err != nil {
		t.Fatalf("UpdateStatus: %v", err)
	}

	out := captureStdout(t, func() {
		cmd := cmdState()
		cmd.SetArgs([]string{"recover", "wf-recover-cli"})
		if err := cmd.Execute(); err != nil {
			t.Fatalf("Execute: %v", err)
		}
	})

	for _, want := range []string{
		"Recovered workflow wf-recover-cli",
		"Status: failed",
		"Version:",
		"Workflow was running during crash. Review state before resuming.",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("expected recover output to contain %q, got %q", want, out)
		}
	}
}

func saveCheckpointFixture(
	t *testing.T,
	manager *agentctx.CheckpointManager,
	threadID string,
	model string,
	iteration int,
	texts []string,
) {
	t.Helper()

	if err := manager.CreateThread(context.Background(), threadID, model, nil); err != nil {
		t.Fatalf("CreateThread: %v", err)
	}
	messages := make([]agentctx.StrategicMessage, 0, len(texts))
	for i, text := range texts {
		role := agentctx.RoleUser
		if i%2 == 1 {
			role = agentctx.RoleAssistant
		}
		text := text
		messages = append(messages, agentctx.StrategicMessage{
			Role:    role,
			Content: &agentctx.MessageContent{Str: &text},
		})
	}
	if _, err := manager.SaveSnapshot(context.Background(), threadID, iteration, messages); err != nil {
		t.Fatalf("SaveSnapshot: %v", err)
	}
}

func captureStdout(t *testing.T, fn func()) string {
	t.Helper()

	original := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("Pipe: %v", err)
	}
	os.Stdout = w
	t.Cleanup(func() { os.Stdout = original })

	fn()

	if err := w.Close(); err != nil {
		t.Fatalf("Close writer: %v", err)
	}
	os.Stdout = original

	out, err := io.ReadAll(r)
	if err != nil {
		t.Fatalf("ReadAll: %v", err)
	}
	return string(out)
}
