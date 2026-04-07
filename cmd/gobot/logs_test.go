package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCmdLogs(t *testing.T) {
	// Setup a temporary home directory to isolate config
	homeDir := t.TempDir()
	os.Setenv("USERPROFILE", homeDir)
	os.Setenv("HOME", homeDir)
	defer func() {
		os.Unsetenv("USERPROFILE")
		os.Unsetenv("HOME")
	}()

	// Setup config
	cfgDir := filepath.Join(homeDir, ".gobot")
	if err := os.MkdirAll(cfgDir, 0755); err != nil {
		t.Fatal(err)
	}

	storageRoot := filepath.Join(homeDir, "Gobot_Storage")
	cfgData := fmt.Sprintf(`{"strategic_edition": {"storage_root": "%s"}}`, filepath.ToSlash(storageRoot))
	if err := os.WriteFile(filepath.Join(cfgDir, "config.json"), []byte(cfgData), 0600); err != nil {
		t.Fatal(err)
	}

	logsDir := filepath.Join(storageRoot, "logs")
	if err := os.MkdirAll(logsDir, 0755); err != nil {
		t.Fatal(err)
	}

	// Create dummy log files
	now := time.Now()
	// Older log file
	olderLog := filepath.Join(logsDir, fmt.Sprintf("gobot_%s.log", now.Add(-10*time.Hour).Format("20060102_150405")))
	if err := os.WriteFile(olderLog, []byte("time=2026-04-03T10:00:00Z level=INFO msg=\"old message\"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(olderLog, now.Add(-10*time.Hour), now.Add(-10*time.Hour)); err != nil {
		t.Fatal(err)
	}

	// Newer log file
	timeStr1 := now.Add(-5 * time.Minute).Format(time.RFC3339Nano)
	timeStr2 := now.Add(-1 * time.Minute).Format(time.RFC3339Nano)

	newerLog := filepath.Join(logsDir, fmt.Sprintf("gobot_%s.log", now.Format("20060102_150405")))
	newerContent := fmt.Sprintf("time=%s level=INFO msg=\"hello world\"\ntime=%s level=ERROR msg=\"an error occurred\"\ntime=%s level=DEBUG msg=\"debug message\"\n", timeStr1, timeStr2, now.Format(time.RFC3339Nano))

	if err := os.WriteFile(newerLog, []byte(newerContent), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(newerLog, now, now); err != nil {
		t.Fatal(err)
	}

	// Helper to run command and capture output
	runCmd := func(args []string) string {
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

	// Test 1: Basic functionality (no flags, should show all lines of latest log)
	out := runCmd([]string{})
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
	out = runCmd([]string{"--lines", "1"})
	if strings.Contains(out, "hello world") {
		t.Errorf("Should not contain first line when lines=1")
	}
	if !strings.Contains(out, "debug message") {
		t.Errorf("Should contain last line 'debug message'")
	}

	// Test 3: Filter flag
	out = runCmd([]string{"--filter", "ERROR"})
	if strings.Contains(out, "hello world") {
		t.Errorf("Should not contain INFO log")
	}
	if !strings.Contains(out, "an error occurred") {
		t.Errorf("Should contain ERROR log")
	}

	// Test 4: Since flag
	out = runCmd([]string{"--since", "2m"})
	if strings.Contains(out, "hello world") {
		t.Errorf("Should not contain log from 5m ago")
	}
	if !strings.Contains(out, "an error occurred") {
		t.Errorf("Should contain log from 1m ago")
	}

	// Test 5: Malformed timestamp handling
	// Create a new log file that's even newer to be the latest
	timeStr3 := now.Add(1 * time.Second).Format(time.RFC3339Nano)
	malformedLog := filepath.Join(logsDir, fmt.Sprintf("gobot_%d.log", now.Unix()+1000))
	malformedContent := fmt.Sprintf("time=INVALID-TIMESTAMP level=INFO msg=\"malformed\"\ntime=%s level=ERROR msg=\"valid error\"\n", timeStr3)
	if err := os.WriteFile(malformedLog, []byte(malformedContent), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(malformedLog, now.Add(1*time.Second), now.Add(1*time.Second)); err != nil {
		t.Fatal(err)
	}

	// Malformed lines should be skipped entirely
	out = runCmd([]string{"--filter", "ERROR"})
	if strings.Contains(out, "malformed") {
		t.Errorf("Should skip line with malformed timestamp")
	}
	if !strings.Contains(out, "valid error") {
		t.Errorf("Should still show properly formatted ERROR logs")
	}
}

func TestLogsCommand_NoLogs(t *testing.T) {
	homeDir := t.TempDir()
	os.Setenv("USERPROFILE", homeDir)
	os.Setenv("HOME", homeDir)
	defer func() {
		os.Unsetenv("USERPROFILE")
		os.Unsetenv("HOME")
	}()

	cfgDir := filepath.Join(homeDir, ".gobot")
	if err := os.MkdirAll(cfgDir, 0755); err != nil {
		t.Fatal(err)
	}

	storageRoot := filepath.Join(homeDir, "Gobot_Storage")
	cfgData := fmt.Sprintf(`{"strategic_edition": {"storage_root": "%s"}}`, filepath.ToSlash(storageRoot))
	if err := os.WriteFile(filepath.Join(cfgDir, "config.json"), []byte(cfgData), 0600); err != nil {
		t.Fatal(err)
	}

	cmd := cmdLogs()
	b := bytes.NewBufferString("")
	cmd.SetOut(b)
	err := cmd.Execute()
	if err == nil {
		t.Errorf("Expected error for no logs, got nil")
	}
}

func TestLogsCommand_LinesBoundsValidation(t *testing.T) {
	homeDir := t.TempDir()
	os.Setenv("USERPROFILE", homeDir)
	os.Setenv("HOME", homeDir)
	defer func() {
		os.Unsetenv("USERPROFILE")
		os.Unsetenv("HOME")
	}()

	// Setup config and logs
	cfgDir := filepath.Join(homeDir, ".gobot")
	if err := os.MkdirAll(cfgDir, 0755); err != nil {
		t.Fatal(err)
	}

	storageRoot := filepath.Join(homeDir, "Gobot_Storage")
	cfgData := fmt.Sprintf(`{"strategic_edition": {"storage_root": "%s"}}`, filepath.ToSlash(storageRoot))
	if err := os.WriteFile(filepath.Join(cfgDir, "config.json"), []byte(cfgData), 0600); err != nil {
		t.Fatal(err)
	}

	logsDir := filepath.Join(storageRoot, "logs")
	if err := os.MkdirAll(logsDir, 0755); err != nil {
		t.Fatal(err)
	}

	logFile := filepath.Join(logsDir, "gobot_test.log")
	if err := os.WriteFile(logFile, []byte("time=2026-04-03T10:00:00Z level=INFO msg=\"test\"\n"), 0600); err != nil {
		t.Fatal(err)
	}

	runTest := func(linesVal string, expectErr bool) {
		cmd := cmdLogs()
		cmd.SetArgs([]string{"--lines", linesVal})
		b := bytes.NewBufferString("")
		cmd.SetOut(b)
		err := cmd.Execute()

		if expectErr && err == nil {
			t.Errorf("Expected error for --lines=%s, got nil", linesVal)
		}
		if !expectErr && err != nil {
			t.Errorf("Expected no error for --lines=%s, got: %v", linesVal, err)
		}
	}

	// Test invalid values
	runTest("0", true)
	runTest("-1", true)
	runTest("-100", true)

	// Test valid values
	runTest("1", false)
	runTest("100", false)
}

func TestLogsCommand_FollowContextCancellation(t *testing.T) {
	homeDir := t.TempDir()
	os.Setenv("USERPROFILE", homeDir)
	os.Setenv("HOME", homeDir)
	defer func() {
		os.Unsetenv("USERPROFILE")
		os.Unsetenv("HOME")
	}()

	// Setup config and logs
	cfgDir := filepath.Join(homeDir, ".gobot")
	if err := os.MkdirAll(cfgDir, 0755); err != nil {
		t.Fatal(err)
	}

	storageRoot := filepath.Join(homeDir, "Gobot_Storage")
	cfgData := fmt.Sprintf(`{"strategic_edition": {"storage_root": "%s"}}`, filepath.ToSlash(storageRoot))
	if err := os.WriteFile(filepath.Join(cfgDir, "config.json"), []byte(cfgData), 0600); err != nil {
		t.Fatal(err)
	}

	logsDir := filepath.Join(storageRoot, "logs")
	if err := os.MkdirAll(logsDir, 0755); err != nil {
		t.Fatal(err)
	}

	logFile := filepath.Join(logsDir, "gobot_test.log")
	if err := os.WriteFile(logFile, []byte("time=2026-04-03T10:00:00Z level=INFO msg=\"test\"\n"), 0600); err != nil {
		t.Fatal(err)
	}

	cmd := cmdLogs()
	cmd.SetArgs([]string{"--follow"})
	b := bytes.NewBufferString("")
	cmd.SetOut(b)

	// Create a context that will be cancelled
	ctx, cancel := context.WithCancel(context.Background())
	cmd.SetContext(ctx)

	// Start command in goroutine
	done := make(chan error, 1)
	go func() {
		done <- cmd.Execute()
	}()

	// Give the command time to enter follow loop
	time.Sleep(100 * time.Millisecond)

	// Cancel context
	cancel()

	// Wait for completion with timeout
	select {
	case err := <-done:
		if err != nil {
			// Context cancellation error is expected
			if !strings.Contains(err.Error(), "context") {
				t.Errorf("Expected context-related error, got: %v", err)
			}
		}
	case <-time.After(2 * time.Second):
		t.Errorf("Command did not exit after context cancellation")
	}
}
