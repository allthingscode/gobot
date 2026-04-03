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
	os.MkdirAll(cfgDir, 0755)
	
	storageRoot := filepath.Join(homeDir, "Gobot_Storage")
	cfgData := fmt.Sprintf(`{"strategic_edition": {"storage_root": "%s"}}`, filepath.ToSlash(storageRoot))
	os.WriteFile(filepath.Join(cfgDir, "config.json"), []byte(cfgData), 0644)

	logsDir := filepath.Join(storageRoot, "logs")
	os.MkdirAll(logsDir, 0755)

	// Create dummy log files
	now := time.Now()
	// Older log file
	olderLog := filepath.Join(logsDir, fmt.Sprintf("gobot_%s.log", now.Add(-10*time.Hour).Format("20060102_150405")))
	os.WriteFile(olderLog, []byte("time=2026-04-03T10:00:00Z level=INFO msg=\"old message\"\n"), 0644)
	os.Chtimes(olderLog, now.Add(-10*time.Hour), now.Add(-10*time.Hour))

	// Newer log file
	timeStr1 := now.Add(-5 * time.Minute).Format(time.RFC3339Nano)
	timeStr2 := now.Add(-1 * time.Minute).Format(time.RFC3339Nano)

	newerLog := filepath.Join(logsDir, fmt.Sprintf("gobot_%s.log", now.Format("20060102_150405")))
	newerContent := fmt.Sprintf("time=%s level=INFO msg=\"hello world\"\ntime=%s level=ERROR msg=\"an error occurred\"\ntime=%s level=DEBUG msg=\"debug message\"\n", timeStr1, timeStr2, now.Format(time.RFC3339Nano))

	os.WriteFile(newerLog, []byte(newerContent), 0644)
	os.Chtimes(newerLog, now, now)

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
	os.WriteFile(malformedLog, []byte(malformedContent), 0644)
	os.Chtimes(malformedLog, now.Add(1*time.Second), now.Add(1*time.Second))

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
	os.MkdirAll(cfgDir, 0755)
	
	storageRoot := filepath.Join(homeDir, "Gobot_Storage")
	cfgData := fmt.Sprintf(`{"strategic_edition": {"storage_root": "%s"}}`, filepath.ToSlash(storageRoot))
	os.WriteFile(filepath.Join(cfgDir, "config.json"), []byte(cfgData), 0644)

	cmd := cmdLogs()
	b := bytes.NewBufferString("")
	cmd.SetOut(b)
	err := cmd.Execute()
	if err == nil {
		t.Errorf("Expected error for no logs, got nil")
	}
}
