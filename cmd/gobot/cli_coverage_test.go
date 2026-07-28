package main

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/secrets"
	"github.com/spf13/cobra"
)

func setupTestHome(t *testing.T) string {
	t.Helper()
	tempDir, err := os.MkdirTemp("", "gobot-test-*")
	if err != nil {
		t.Fatalf("MkdirTemp: %v", err)
	}

	// Normalize path to avoid short name issues on Windows.
	if absDir, err := filepath.Abs(tempDir); err == nil {
		tempDir = absDir
	}
	if evalDir, err := filepath.EvalSymlinks(tempDir); err == nil {
		tempDir = evalDir
	}
	tempDir = filepath.Clean(tempDir)

	t.Setenv("GOBOT_HOME", tempDir)
	t.Setenv("GOBOT_STORAGE", tempDir)
	t.Setenv("GOBOT_ENCRYPTION_KEY_FILE", filepath.Join(tempDir, "encryption.key"))

	t.Cleanup(func() {
		_ = os.RemoveAll(tempDir)
	})
	return tempDir
}

//nolint:paralleltest // uses global state
func TestCmdVersion(t *testing.T) {
	cmd := cmdVersion()
	out := bytes.NewBuffer(nil)
	cmd.SetOut(out)

	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	got := out.String()
	if !strings.Contains(got, "gobot ") {
		t.Fatalf("expected version line, got %q", got)
	}
	if !strings.Contains(got, "runtime:") {
		t.Fatalf("expected runtime line, got %q", got)
	}
}

//nolint:paralleltest // uses global state
func TestCmdInitCreatesWorkspace(t *testing.T) {
	tempDir := setupTestHome(t)
	cmd := cmdInit()
	out := bytes.NewBuffer(nil)
	cmd.SetOut(out)
	cmd.SetArgs([]string{"--root", tempDir})

	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	got := out.String()
	if !strings.Contains(got, "Initialized gobot workspace at "+tempDir) {
		t.Fatalf("expected init output for temp root, got %q", got)
	}
	for _, dir := range []string{"sessions", "secrets", "memory", "logs"} {
		if _, err := os.Stat(filepath.Join(tempDir, "workspace", dir)); err != nil {
			t.Fatalf("expected workspace dir %s: %v", dir, err)
		}
	}
	if _, err := os.Stat(filepath.Join(tempDir, ".gobot", "config.json")); err != nil {
		t.Fatalf("expected config file: %v", err)
	}
}

//nolint:paralleltest // uses global state
func TestCmdLogsPrintsSelectedLogContent(t *testing.T) {
	tempDir := setupTestHome(t)
	logDir := filepath.Join(tempDir, "logs")
	if err := os.MkdirAll(logDir, 0o755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	if err := os.WriteFile(filepath.Join(logDir, "gobot.log"), []byte("first\nselected log\n"), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	cmd := cmdLogs()
	out := bytes.NewBuffer(nil)
	cmd.SetOut(out)
	cmd.SetArgs([]string{"--lines", "1"})

	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	got := out.String()
	if !strings.Contains(got, "selected log") {
		t.Fatalf("expected selected log line, got %q", got)
	}
	if strings.Contains(got, "first") {
		t.Fatalf("expected only one tailed line, got %q", got)
	}
}

//nolint:paralleltest // uses global state
func TestCmdConfigReformatReportsSuccess(t *testing.T) {
	tempDir := setupTestHome(t)
	cfg := &config.Config{}
	cfg.Runtime.StorageRoot = tempDir
	configPath := filepath.Join(tempDir, ".gobot", "config.json")
	if err := cfg.Save(configPath); err != nil {
		t.Fatalf("Save: %v", err)
	}

	out := captureStdout(t, func() {
		cmd := cmdConfig()
		cmd.SetArgs([]string{"reformat", configPath})
		if err := cmd.Execute(); err != nil {
			t.Fatalf("Execute: %v", err)
		}
	})

	if !strings.Contains(out, "Successfully reformatted "+configPath) {
		t.Fatalf("expected reformat success output, got %q", out)
	}
}

//nolint:paralleltest // uses global state
func TestConfigReformatReturnsLoadErrorForInvalidConfig(t *testing.T) {
	tempDir := setupTestHome(t)
	configPath := filepath.Join(tempDir, ".gobot", "config.json")
	if err := os.MkdirAll(filepath.Dir(configPath), 0o755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	if err := os.WriteFile(configPath, []byte("invalid json"), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	cmd := cmdConfig()
	cmd.SetArgs([]string{"reformat", configPath})
	err := cmd.Execute()
	if err == nil {
		t.Fatal("expected invalid config error")
	}
	if !strings.Contains(err.Error(), "load config") || !strings.Contains(err.Error(), "invalid field or syntax") {
		t.Fatalf("expected wrapped config load error, got %v", err)
	}
}

//nolint:paralleltest // uses global state
func TestCmdSecretsSetAndGetRoundTrip(t *testing.T) {
	tempDir := setupTestHome(t)

	setOut := captureStdout(t, func() {
		cmd := cmdSecretsSet()
		cmd.SetArgs([]string{"key1", "val1"})
		if err := cmd.Execute(); err != nil {
			t.Fatalf("set Execute: %v", err)
		}
	})
	if !strings.Contains(setOut, `Secret "key1" stored.`) {
		t.Fatalf("expected set confirmation, got %q", setOut)
	}

	getOut := captureStdout(t, func() {
		cmd := cmdSecretsGet()
		cmd.SetArgs([]string{"key1"})
		if err := cmd.Execute(); err != nil {
			t.Fatalf("get Execute: %v", err)
		}
	})
	if strings.TrimSpace(getOut) != "val1" {
		t.Fatalf("secret get output = %q, want val1", getOut)
	}

	store := secrets.NewSecretsStore(tempDir)
	if got, err := store.Get("key1"); err != nil || got != "val1" {
		t.Fatalf("persisted secret = %q, err %v", got, err)
	}
}

//nolint:paralleltest // uses global state
func TestCmdCheckpointsListReportsEmptyStore(t *testing.T) {
	tempDir := setupTestHome(t)
	if err := os.MkdirAll(filepath.Join(tempDir, "workspace"), 0o755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}

	out := captureStdout(t, func() {
		cmd := cmdCheckpoints()
		if err := cmd.Execute(); err != nil {
			t.Fatalf("Execute: %v", err)
		}
	})

	if !strings.Contains(out, "No resumable checkpoints found.") {
		t.Fatalf("expected empty checkpoint output, got %q", out)
	}
}

//nolint:paralleltest // uses global state
func TestCmdResumeReportsMissingCheckpoint(t *testing.T) {
	tempDir := setupTestHome(t)
	writeTestConfig(t, tempDir)

	out := captureStdout(t, func() {
		cmd := cmdResume()
		cmd.SetArgs([]string{"nonexistent-thread"})
		if err := cmd.Execute(); err != nil {
			t.Fatalf("Execute: %v", err)
		}
	})

	if !strings.Contains(out, "No checkpoint found for thread: nonexistent-thread") {
		t.Fatalf("expected missing checkpoint output, got %q", out)
	}
}

//nolint:paralleltest // uses global state
func TestCmdClearCheckpointIsIdempotentForMissingThread(t *testing.T) {
	tempDir := setupTestHome(t)
	writeTestConfig(t, tempDir)

	out := captureStdout(t, func() {
		cmd := cmdClearCheckpoint()
		cmd.SetArgs([]string{"nonexistent-thread"})
		if err := cmd.Execute(); err != nil {
			t.Fatalf("Execute: %v", err)
		}
	})

	if !strings.Contains(out, "Successfully marked session nonexistent-thread as completed.") {
		t.Fatalf("expected idempotent clear output, got %q", out)
	}
}

//nolint:paralleltest // uses global state
func TestCmdStateListReportsEmptyState(t *testing.T) {
	tempDir := setupTestHome(t)
	writeTestConfig(t, tempDir)

	out := captureStdout(t, func() {
		cmd := cmdState()
		cmd.SetArgs([]string{"list"})
		if err := cmd.Execute(); err != nil {
			t.Fatalf("Execute: %v", err)
		}
	})

	if !strings.Contains(out, "No active workflows") {
		t.Fatalf("expected empty state output, got %q", out)
	}
}

//nolint:paralleltest // uses global state
func TestCmdStateMissingWorkflowErrors(t *testing.T) {
	tempDir := setupTestHome(t)
	writeTestConfig(t, tempDir)

	tests := []struct {
		name     string
		args     []string
		wantText string
	}{
		{name: "inspect", args: []string{"inspect", "nonexistent-wf"}, wantText: "loading workflow"},
		{name: "archive", args: []string{"archive", "nonexistent-wf"}, wantText: "archiving workflow"},
		{name: "recover", args: []string{"recover", "nonexistent-wf"}, wantText: "recovering workflow"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			cmd := cmdState()
			cmd.SetArgs(tc.args)
			err := cmd.Execute()
			if err == nil {
				t.Fatal("expected missing workflow error")
			}
			if !strings.Contains(err.Error(), tc.wantText) {
				t.Fatalf("expected %q context, got %v", tc.wantText, err)
			}
		})
	}
}

//nolint:paralleltest // uses global state
func TestCmdTasksRequireOAuthToken(t *testing.T) {
	tempDir := setupTestHome(t)
	writeTestConfig(t, tempDir)

	tests := []struct {
		name string
		args []string
		want string
	}{
		{name: "list", args: []string{"list"}, want: "tasks auth"},
		{name: "add", args: []string{"add", "test task"}, want: "create task"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			cmd := cmdTasks()
			cmd.SetArgs(tc.args)
			err := cmd.Execute()
			if err == nil {
				t.Fatal("expected OAuth token error")
			}
			if !strings.Contains(err.Error(), tc.want) || !strings.Contains(err.Error(), "google_token.json not found") {
				t.Fatalf("expected deterministic auth error, got %v", err)
			}
		})
	}
}

func TestGoogleCommandArgumentValidation(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		cmd  *cobra.Command
		args []string
		want string
	}{
		{name: "email requires subject and body", cmd: cmdEmail(), want: "accepts 2 arg"},
		{name: "tasks add requires title", cmd: cmdTasks(), args: []string{"add"}, want: "requires at least 1 arg"},
		{name: "authorize requires one arg", cmd: cmdAuthorize(), want: "accepts 1 arg"},
	}
	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			tc.cmd.SetArgs(tc.args)
			err := tc.cmd.Execute()
			if err == nil {
				t.Fatal("expected argument validation error")
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("expected error containing %q, got %v", tc.want, err)
			}
		})
	}
}

//nolint:paralleltest // uses global env/config and cached checkpoint handles
func TestCmdAuthorizeRejectsInvalidPairingOrChatID(t *testing.T) {
	tempDir := setupTestHome(t)
	writeTestConfig(t, tempDir)

	cmd := cmdAuthorize()
	cmd.SetArgs([]string{"not-a-code"})
	err := cmd.Execute()
	if err == nil {
		t.Fatal("expected invalid authorization argument error")
	}
	if !strings.Contains(err.Error(), "not a valid pairing code or numeric chat ID") {
		t.Fatalf("expected invalid pairing/chat ID error, got %v", err)
	}
	agentctx.EvictCheckpointManagerForTest(tempDir)
}

//nolint:paralleltest // mutates global config environment
func TestGoogleCommandsWrapConfigLoadErrors(t *testing.T) {
	tempDir := setupTestHome(t)
	configPath := filepath.Join(tempDir, ".gobot", "config.json")
	if err := os.MkdirAll(filepath.Dir(configPath), 0o755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	if err := os.WriteFile(configPath, []byte("{bad json"), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	tests := []struct {
		name string
		cmd  *cobra.Command
		args []string
		want string
	}{
		{name: "reauth", cmd: cmdReauth(), want: "config:"},
		{name: "email", cmd: cmdEmail(), args: []string{"subject", "body"}, want: "config:"},
		{name: "calendar", cmd: cmdCalendar(), want: "config:"},
		{name: "tasks list", cmd: cmdTasks(), args: []string{"list"}, want: "config:"},
		{name: "tasks add", cmd: cmdTasks(), args: []string{"add", "title"}, want: "config:"},
		{name: "authorize", cmd: cmdAuthorize(), args: []string{"123"}, want: "config:"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			tc.cmd.SetArgs(tc.args)
			err := tc.cmd.Execute()
			if err == nil {
				t.Fatal("expected config load error")
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("expected %q in error, got %v", tc.want, err)
			}
		})
	}
}

func TestCmdSimulateRequiresPrompt(t *testing.T) {
	t.Parallel()

	cmd := cmdSimulate()
	err := cmd.Execute()
	if err == nil {
		t.Fatal("expected missing prompt error")
	}
	if !strings.Contains(err.Error(), "accepts 1 arg") {
		t.Fatalf("expected argument validation error, got %v", err)
	}
}

//nolint:paralleltest // uses global state
func TestCmdAuthorizeDirectChatID(t *testing.T) {
	tempDir := setupTestHome(t)
	writeTestConfig(t, tempDir)

	out := captureStdout(t, func() {
		cmd := cmdAuthorize()
		cmd.SetArgs([]string{"12345"})
		if err := cmd.Execute(); err != nil {
			t.Fatalf("Execute: %v", err)
		}
	})

	if !strings.Contains(out, "Authorized chat ID 12345 directly.") {
		t.Fatalf("expected direct authorization output, got %q", out)
	}
}

//nolint:paralleltest // uses global state
func TestCmdEmailRequiresConfiguredRecipient(t *testing.T) {
	tempDir := setupTestHome(t)
	writeTestConfig(t, tempDir)

	cmd := cmdEmail()
	cmd.SetArgs([]string{"subject", "body"})
	err := cmd.Execute()
	if err == nil {
		t.Fatal("expected missing user email error")
	}
	if !strings.Contains(err.Error(), "runtime.user_email not set") {
		t.Fatalf("expected recipient configuration error, got %v", err)
	}
}

//nolint:paralleltest // uses global state
func TestCmdCalendarRequiresOAuthToken(t *testing.T) {
	tempDir := setupTestHome(t)
	writeTestConfig(t, tempDir)

	cmd := cmdCalendar()
	err := cmd.Execute()
	if err == nil {
		t.Fatal("expected OAuth token error")
	}
	if !strings.Contains(err.Error(), "calendar") || !strings.Contains(err.Error(), "google_token.json not found") {
		t.Fatalf("expected deterministic auth error, got %v", err)
	}
}

//nolint:paralleltest // uses global state
func TestCmdMemorySearchReportsEmptyResults(t *testing.T) {
	tempDir := setupTestHome(t)
	writeTestConfig(t, tempDir)

	out := captureStdout(t, func() {
		cmd := cmdMemory()
		cmd.SetArgs([]string{"search", "missing"})
		if err := cmd.Execute(); err != nil {
			t.Fatalf("Execute: %v", err)
		}
	})

	if !strings.Contains(out, "No results found.") {
		t.Fatalf("expected empty memory search output, got %q", out)
	}
}

//nolint:paralleltest // uses global state
func TestCmdMemoryRebuildReportsIndexedCount(t *testing.T) {
	tempDir := setupTestHome(t)
	writeTestConfig(t, tempDir)
	if err := os.MkdirAll(filepath.Join(tempDir, "workspace", "sessions"), 0o755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}

	out := captureStdout(t, func() {
		cmd := cmdMemory()
		cmd.SetArgs([]string{"rebuild"})
		if err := cmd.Execute(); err != nil {
			t.Fatalf("Execute: %v", err)
		}
	})

	if !strings.Contains(out, "Memory index rebuilt: 0 session files indexed.") {
		t.Fatalf("expected rebuild count output, got %q", out)
	}
}

//nolint:paralleltest // uses global state
func TestCmdConfigValidateReturnsExitCodeErrorForInvalidConfig(t *testing.T) {
	tempDir := setupTestHome(t)
	configPath := filepath.Join(tempDir, ".gobot", "config.json")
	if err := os.MkdirAll(filepath.Dir(configPath), 0o755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	if err := os.WriteFile(configPath, []byte("invalid json"), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	cmd := cmdConfig()
	cmd.SetArgs([]string{"validate", configPath})
	err := cmd.Execute()
	if err == nil {
		t.Fatal("expected validation error")
	}
	var exitErr *exitCodeError
	if !errors.As(err, &exitErr) {
		t.Fatalf("expected exitCodeError, got %T: %v", err, err)
	}
	if exitErr.code != 1 {
		t.Fatalf("exit code = %d, want 1", exitErr.code)
	}
	if !strings.Contains(err.Error(), "failed to load config") {
		t.Fatalf("expected config load context, got %v", err)
	}
}

func writeTestConfig(t *testing.T, storageRoot string) {
	t.Helper()
	cfg := &config.Config{}
	cfg.Runtime.StorageRoot = storageRoot
	if err := cfg.Save(filepath.Join(storageRoot, ".gobot", "config.json")); err != nil {
		t.Fatalf("Save: %v", err)
	}
}
