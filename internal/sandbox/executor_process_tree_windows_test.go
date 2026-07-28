//go:build windows

package sandbox_test

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/sandbox"
	"golang.org/x/sys/windows"
)

const sandboxHelperEnv = "GOBOT_SANDBOX_HELPER"

func TestExecutorCancelsProcessTree(t *testing.T) { //nolint:paralleltest // manipulates inherited helper env and process tree state
	ctx, cancel := context.WithCancel(context.Background())
	pidFile := sandboxProcessTreeHelper(t, ctx, sandbox.Config{SandboxRoot: t.TempDir()})

	grandchildPID := waitForHelperPID(t, pidFile)
	t.Cleanup(func() { terminateProcessIfAlive(t, grandchildPID) })

	cancel()
	waitForProcessExit(t, grandchildPID, 5*time.Second)
}

func TestExecutorTimeoutKillsProcessTree(t *testing.T) { //nolint:paralleltest // manipulates inherited helper env and process tree state
	pidFile := sandboxProcessTreeHelper(t, context.Background(), sandbox.Config{
		SandboxRoot: t.TempDir(),
		Timeout:     750 * time.Millisecond,
	})

	grandchildPID := waitForHelperPID(t, pidFile)
	t.Cleanup(func() { terminateProcessIfAlive(t, grandchildPID) })

	waitForProcessExit(t, grandchildPID, 5*time.Second)
}

func TestExecutorEnforcesMemoryLimit(t *testing.T) {
	t.Setenv(sandboxHelperEnv, "1")

	runner := sandbox.New(sandbox.Config{
		SandboxRoot: t.TempDir(),
		MaxMemoryMB: 32,
		Timeout:     10 * time.Second,
	})

	output, err := runner.Run(context.Background(), os.Args[0], []string{
		"-test.run=^TestSandboxHelperProcess$",
		"--",
		"memory",
	})
	if err == nil {
		t.Fatalf("expected memory limit to terminate helper, got nil error and output %q", output)
	}
	if strings.Contains(output, "memory-helper-finished") {
		t.Fatalf("memory helper completed without limit enforcement: %q", output)
	}
}

func sandboxProcessTreeHelper(t *testing.T, ctx context.Context, cfg sandbox.Config) string {
	t.Helper()
	t.Setenv(sandboxHelperEnv, "1")

	pidFile := t.TempDir() + `\grandchild.pid`
	done := make(chan runResult, 1)
	runner := sandbox.New(cfg)
	go func() {
		output, err := runner.Run(ctx, os.Args[0], []string{
			"-test.run=^TestSandboxHelperProcess$",
			"--",
			"tree-parent",
			pidFile,
		})
		done <- runResult{output: output, err: err}
	}()

	t.Cleanup(func() {
		select {
		case result := <-done:
			if result.err == nil {
				t.Errorf("expected sandbox helper to be terminated, got nil error and output %q", result.output)
			}
		case <-time.After(5 * time.Second):
			t.Error("sandbox helper did not exit within cleanup deadline")
		}
	})

	return pidFile
}

type runResult struct {
	output string
	err    error
}

func TestSandboxHelperProcess(t *testing.T) { //nolint:paralleltest // helper mode intentionally blocks or allocates memory
	if os.Getenv(sandboxHelperEnv) != "1" {
		return
	}

	args := helperArgs()
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "missing helper mode")
		os.Exit(2)
	}

	switch args[0] {
	case "tree-parent":
		runTreeParentHelper(args[1:])
	case "tree-grandchild":
		sleepForever()
	case "memory":
		runMemoryHelper()
	default:
		fmt.Fprintf(os.Stderr, "unknown helper mode %q\n", args[0])
		os.Exit(2)
	}
}

func helperArgs() []string {
	for i, arg := range os.Args {
		if arg == "--" {
			return os.Args[i+1:]
		}
	}
	return nil
}

func runTreeParentHelper(args []string) {
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "tree-parent requires pid file path")
		os.Exit(2)
	}

	cmd := exec.CommandContext(context.Background(), os.Args[0], "-test.run=^TestSandboxHelperProcess$", "--", "tree-grandchild") //nolint:gosec // test helper executes current test binary
	cmd.Env = os.Environ()
	if err := cmd.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "start grandchild: %v\n", err)
		os.Exit(2)
	}

	if err := writeHelperPIDFile(args[0], cmd.Process.Pid); err != nil {
		_ = cmd.Process.Kill()
		fmt.Fprintf(os.Stderr, "write pid file: %v\n", err)
		os.Exit(2)
	}

	sleepForever()
}

func writeHelperPIDFile(pidFile string, pid int) error {
	dir := filepath.Dir(pidFile)
	tmp, err := os.CreateTemp(dir, ".grandchild-*.pid")
	if err != nil {
		return fmt.Errorf("create temp PID file: %w", err)
	}
	tmpName := tmp.Name()
	removeTmp := true
	defer func() {
		if removeTmp {
			_ = os.Remove(tmpName)
		}
	}()

	if _, err := tmp.WriteString(strconv.Itoa(pid)); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("write temp PID file: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close temp PID file: %w", err)
	}
	if err := os.Chmod(tmpName, 0o600); err != nil {
		return fmt.Errorf("chmod temp PID file: %w", err)
	}
	if err := os.Rename(tmpName, pidFile); err != nil {
		return fmt.Errorf("rename temp PID file: %w", err)
	}
	removeTmp = false
	return nil
}

func runMemoryHelper() {
	fmt.Println("memory-helper-started")

	const chunkSize = 1 << 20
	blocks := make([][]byte, 0, 128)
	for i := 0; i < 128; i++ {
		block := make([]byte, chunkSize)
		for j := range block {
			block[j] = byte(j)
		}
		blocks = append(blocks, block)
		time.Sleep(10 * time.Millisecond)
	}

	fmt.Println("memory-helper-finished", len(blocks))
}

func sleepForever() {
	for {
		time.Sleep(time.Hour)
	}
}

func waitForHelperPID(t *testing.T, pidFile string) uint32 {
	t.Helper()

	deadline := time.Now().Add(5 * time.Second)
	var lastRead string
	var lastParseErr error
	for time.Now().Before(deadline) {
		raw, err := os.ReadFile(pidFile)
		if err == nil {
			lastRead = string(raw)
			pidText := strings.TrimSpace(lastRead)
			if pidText != "" {
				pid, parseErr := strconv.ParseUint(pidText, 10, 32)
				if parseErr == nil {
					return uint32(pid)
				}
				lastParseErr = parseErr
			}
		} else if !isPendingHelperPIDRead(err) {
			t.Fatalf("read helper PID file: %v", err)
		}
		time.Sleep(25 * time.Millisecond)
	}

	if lastParseErr != nil {
		t.Fatalf("helper did not report parseable grandchild PID before deadline; last read %q: %v", lastRead, lastParseErr)
	}
	t.Fatalf("helper did not report grandchild PID before deadline")
	return 0
}

func isPendingHelperPIDRead(err error) bool {
	return errors.Is(err, os.ErrNotExist) ||
		errors.Is(err, windows.ERROR_SHARING_VIOLATION) ||
		errors.Is(err, windows.ERROR_LOCK_VIOLATION)
}

func waitForProcessExit(t *testing.T, pid uint32, timeout time.Duration) {
	t.Helper()

	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		alive, err := isProcessAlive(pid)
		if err != nil {
			t.Fatalf("check process %d: %v", pid, err)
		}
		if !alive {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}

	t.Fatalf("process %d still alive after %s", pid, timeout)
}

func terminateProcessIfAlive(t *testing.T, pid uint32) {
	t.Helper()

	handle, err := windows.OpenProcess(windows.PROCESS_TERMINATE|windows.SYNCHRONIZE, false, pid)
	if err != nil {
		if errors.Is(err, windows.ERROR_INVALID_PARAMETER) {
			return
		}
		t.Logf("open process %d for cleanup: %v", pid, err)
		return
	}
	defer func() { _ = windows.CloseHandle(handle) }()

	waitResult, err := windows.WaitForSingleObject(handle, 0)
	if err != nil {
		t.Logf("wait for process %d during cleanup: %v", pid, err)
		return
	}
	if waitResult == uint32(windows.WAIT_TIMEOUT) {
		_ = windows.TerminateProcess(handle, 1)
	}
}

func isProcessAlive(pid uint32) (bool, error) {
	handle, err := windows.OpenProcess(windows.SYNCHRONIZE, false, pid)
	if err != nil {
		if errors.Is(err, windows.ERROR_INVALID_PARAMETER) {
			return false, nil
		}
		return false, fmt.Errorf("OpenProcess: %w", err)
	}
	defer func() { _ = windows.CloseHandle(handle) }()

	waitResult, err := windows.WaitForSingleObject(handle, 0)
	if err != nil {
		return false, fmt.Errorf("WaitForSingleObject: %w", err)
	}
	return waitResult == uint32(windows.WAIT_TIMEOUT), nil
}
