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
const sandboxStartupDelayEnv = "GOBOT_SANDBOX_STARTUP_DELAY"

func TestExecutorCancelsProcessTree(t *testing.T) { //nolint:paralleltest // manipulates inherited helper env and process tree state
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	helper := sandboxProcessTreeHelper(t, ctx, sandbox.Config{SandboxRoot: t.TempDir()})

	grandchildPID := waitForHelperPID(t, helper)
	cancel()
	waitForProcessExit(t, grandchildPID, 5*time.Second)
	helper.wait(t, "Run after cancellation")
}

func TestExecutorTimeoutKillsProcessTree(t *testing.T) { //nolint:paralleltest // manipulates inherited helper env and process tree state
	// Controlled startup pressure exceeds the old 750ms budget. This delay
	// exercises helper startup, rather than sleeping in an assertion loop.
	t.Setenv(sandboxStartupDelayEnv, "1s")
	helper := sandboxProcessTreeHelper(t, context.Background(), sandbox.Config{
		SandboxRoot: t.TempDir(),
		// Startup shares this budget. Concurrent suite/coverage load measured
		// 8.74s to observe readiness. Allow 10s for readiness and 5s for
		// observing a live grandchild before the configured timeout fires.
		Timeout: 15 * time.Second,
	})

	grandchildPID := waitForHelperPID(t, helper)
	waitForProcessExit(t, grandchildPID, 20*time.Second)
	helper.wait(t, "Run after configured timeout")
}

func TestExecutorProcessTreeStartupConsumesTimeout(t *testing.T) { //nolint:paralleltest // inherited helper env
	t.Setenv(sandboxStartupDelayEnv, "1s")
	helper := sandboxProcessTreeHelper(t, context.Background(), sandbox.Config{
		SandboxRoot: t.TempDir(), Timeout: 750 * time.Millisecond,
	})
	helper.wait(t, "configured timeout before readiness")
	select {
	case <-helper.done:
		if _, err := os.Stat(helper.pidFile); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("expected timeout before PID publication, stat error=%v; output=%q", err, helper.result.output)
		}
	default:
		t.Fatal("Run did not complete")
	}
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

func sandboxProcessTreeHelper(t *testing.T, ctx context.Context, cfg sandbox.Config) *treeHelper {
	t.Helper()
	t.Setenv(sandboxHelperEnv, "1")

	pidFile := t.TempDir() + `\grandchild.pid`
	ctx, cancel := context.WithCancel(ctx)
	helper := &treeHelper{pidFile: pidFile, done: make(chan struct{}), started: time.Now()}
	runner := sandbox.New(cfg)
	go func() {
		output, err := runner.Run(ctx, os.Args[0], []string{
			"-test.run=^TestSandboxHelperProcess$",
			"--",
			"tree-parent",
			pidFile,
		})
		helper.result = runResult{output: output, err: err}
		close(helper.done)
	}()

	t.Cleanup(func() {
		cancel() // Also stop Run if readiness or a later assertion fails.
		helper.wait(t, "Run cleanup")
	})

	return helper
}

type treeHelper struct {
	pidFile string
	done    chan struct{}
	result  runResult // Published by closing done; never read before then.
	started time.Time
}

// Five seconds is a termination/pipe-drain allowance, independent of startup.
// Normal waits reserve another five seconds for cleanup before the test deadline.
func treeWaitBound(t *testing.T, bound time.Duration, cleanup bool) time.Duration {
	t.Helper()
	if deadline, ok := t.Deadline(); ok {
		remaining := time.Until(deadline)
		if !cleanup {
			remaining -= 5 * time.Second
		}
		if remaining < bound {
			bound = remaining
		}
	}
	if bound < 0 {
		return 0
	}
	return bound
}

func (h *treeHelper) wait(t *testing.T, stage string) {
	t.Helper()
	select {
	case <-h.done:
		t.Logf("%s: Run completed after %s: %v; output=%q", stage, time.Since(h.started), h.result.err, h.result.output)
		if h.result.err == nil {
			t.Errorf("%s: expected non-nil Run error after %s; output=%q", stage, time.Since(h.started), h.result.output)
		}
	case <-time.After(treeWaitBound(t, 5*time.Second, stage == "Run cleanup")):
		t.Errorf("%s: Run still pending after %s (PID file %s)", stage, time.Since(h.started), h.pidFile)
	}
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
	if delayText := os.Getenv(sandboxStartupDelayEnv); delayText != "" {
		delay, err := time.ParseDuration(delayText)
		if err != nil {
			fmt.Fprintf(os.Stderr, "parse startup delay: %v\n", err)
			os.Exit(2)
		}
		fmt.Printf("tree-parent startup delay %s\n", delay)
		time.Sleep(delay)
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

func waitForHelperPID(t *testing.T, helper *treeHelper) uint32 {
	t.Helper()

	deadline := time.Now().Add(treeWaitBound(t, 10*time.Second, false))
	var lastRead string
	var lastParseErr error
	for time.Now().Before(deadline) {
		select {
		case <-helper.done:
			t.Fatalf("PID readiness: Run exited after %s: %v; output=%q", time.Since(helper.started), helper.result.err, helper.result.output)
		default:
		}
		raw, err := os.ReadFile(helper.pidFile)
		if err == nil {
			lastRead = string(raw)
			pidText := strings.TrimSpace(lastRead)
			if pidText != "" {
				pid, parseErr := strconv.ParseUint(pidText, 10, 32)
				if parseErr == nil {
					return requireLiveGrandchild(t, uint32(pid), helper.started)
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
	t.Fatalf("PID readiness: helper did not report grandchild PID after %s (Run pending, last read %q)", time.Since(helper.started), lastRead)
	return 0
}

func requireLiveGrandchild(t *testing.T, pid uint32, started time.Time) uint32 {
	t.Helper()
	t.Cleanup(func() { terminateProcessIfAlive(t, pid) })
	alive, err := isProcessAlive(pid)
	if err != nil || !alive {
		t.Fatalf("PID readiness: grandchild %d not alive after %s: %v", pid, time.Since(started), err)
	}
	t.Logf("PID readiness: live grandchild after %s", time.Since(started))
	return pid
}

func isPendingHelperPIDRead(err error) bool {
	return errors.Is(err, os.ErrNotExist) ||
		errors.Is(err, windows.ERROR_SHARING_VIOLATION) ||
		errors.Is(err, windows.ERROR_LOCK_VIOLATION)
}

func waitForProcessExit(t *testing.T, pid uint32, timeout time.Duration) {
	t.Helper()

	deadline := time.Now().Add(treeWaitBound(t, timeout, false))
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
