//nolint:testpackage // intentionally uses unexported helpers from main package
package main

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestLogsCommand(t *testing.T) { //nolint:paralleltest // uses global state // modifies global env
	_, logsDir := setupLogsTest(t)
	createTestLogs(t, logsDir)

	// Test 1: Basic functionality (no flags, should show all lines of latest log)
	out := runLogsCmd(t, []string{})
	if !strings.Contains(out, "hello world") {
		t.Errorf("Expected 'hello world' in output, got: %s", out)
	}
	if !strings.Contains(out, "an error occurred") {
		t.Errorf("Expected 'an error occurred' in output")
	}
	if strings.Contains(out, "old message") {
		t.Errorf("Should not contain 'old message' from old log file")
	}

	// Test 2: Lines flag
	out = runLogsCmd(t, []string{"--lines", "1"})
	if strings.Contains(out, "hello world") {
		t.Errorf("Should not contain first line when lines=1")
	}
	if !strings.Contains(out, "debug message") {
		t.Errorf("Should contain last line 'debug message'")
	}

	// Test 3: Filter flag
	out = runLogsCmd(t, []string{"--filter", "error"})
	if strings.Contains(out, "hello world") {
		t.Errorf("Should not contain INFO line when filter=error")
	}
	if !strings.Contains(out, "an error occurred") {
		t.Errorf("Should contain ERROR line")
	}
}

func runLogsCmd(t *testing.T, args []string) string {
	t.Helper()
	cmd := cmdLogs()
	cmd.SetArgs(args)
	b := bytes.NewBufferString("")
	cmd.SetOut(b)
	err := cmd.Execute()
	if err != nil {
		t.Fatalf("cmd.Execute() failed: %v", err)
	}
	return b.String()
}

func setupLogsTest(t *testing.T) (homeDir, logsDir string) {
	t.Helper()
	homeDir, err := os.MkdirTemp("", "gobot-test-logs-*")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(homeDir) })

	origHome := os.Getenv("GOBOT_HOME")
	os.Setenv("GOBOT_HOME", homeDir)
	t.Cleanup(func() {
		os.Setenv("GOBOT_HOME", origHome)
	})

	logsDir = filepath.Join(homeDir, "logs")
	if err := os.MkdirAll(logsDir, 0o755); err != nil {
		t.Fatal(err)
	}

	cfgDir := filepath.Join(homeDir, ".gobot")
	if err := os.MkdirAll(cfgDir, 0o755); err != nil {
		t.Fatal(err)
	}
	cfgData := fmt.Sprintf(`{"strategic_edition": {"storage_root": %q}}`, filepath.ToSlash(homeDir))
	if err := os.WriteFile(filepath.Join(cfgDir, "config.json"), []byte(cfgData), 0o600); err != nil {
		t.Fatal(err)
	}

	return homeDir, logsDir
}

func createTestLogs(t *testing.T, logsDir string) {
	t.Helper()
	now := time.Now()
	// Older log file
	olderLog := filepath.Join(logsDir, fmt.Sprintf("gobot_%s.log", now.Add(-10*time.Hour).Format("20060102_150405")))
	olderContent := "time=2026-04-03T10:00:00Z level=INFO msg=\"old message\"\n"
	_ = os.WriteFile(olderLog, []byte(olderContent), 0o600)
	_ = os.Chtimes(olderLog, now.Add(-10*time.Hour), now.Add(-10*time.Hour))

	// Newer log file
	timeStr1 := now.Add(-5 * time.Minute).Format(time.RFC3339Nano)
	timeStr2 := now.Add(-1 * time.Minute).Format(time.RFC3339Nano)

	newerLog := filepath.Join(logsDir, fmt.Sprintf("gobot_%s.log", now.Format("20060102_150405")))
	newerContent := fmt.Sprintf("time=%s level=INFO msg=\"hello world\"\ntime=%s level=ERROR msg=\"an error occurred\"\ntime=%s level=DEBUG msg=\"debug message\"\n", timeStr1, timeStr2, now.Format(time.RFC3339Nano))

	_ = os.WriteFile(newerLog, []byte(newerContent), 0o600)
	_ = os.Chtimes(newerLog, now, now)
}

func TestLogsCommand_StorageRootOverride(t *testing.T) { //nolint:paralleltest // uses global state // modifies global env
	homeDir, _ := os.MkdirTemp("", "gobot-test-logs-override-*")
	defer os.RemoveAll(homeDir)

	origHome := os.Getenv("GOBOT_HOME")
	os.Setenv("GOBOT_HOME", homeDir)
	defer func() {
		os.Setenv("GOBOT_HOME", origHome)
	}()

	cfgDir := filepath.Join(homeDir, ".gobot")
	_ = os.MkdirAll(cfgDir, 0o755)
	storageRoot := filepath.Join(homeDir, "Gobot_Storage")
	cfgData := fmt.Sprintf(`{"strategic_edition": {"storage_root": %q}}`, filepath.ToSlash(storageRoot))
	_ = os.WriteFile(filepath.Join(cfgDir, "config.json"), []byte(cfgData), 0o600)

	logsDir := filepath.Join(storageRoot, "logs")
	_ = os.MkdirAll(logsDir, 0o755)
	logFile := filepath.Join(logsDir, "gobot_20260403_120000.log")
	_ = os.WriteFile(logFile, []byte("level=INFO msg=\"override test\"\n"), 0o600)

	out := runLogsCmd(t, []string{})
	if !strings.Contains(out, "override test") {
		t.Errorf("Expected 'override test', got: %s", out)
	}
}
