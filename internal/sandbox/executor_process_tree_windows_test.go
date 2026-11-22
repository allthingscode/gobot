//go:build windows

//nolint:testpackage // injects the private executor timeout factory
package sandbox

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

	"golang.org/x/sys/windows"
)

const sandboxHelperEnv = "GOBOT_SANDBOX_HELPER"
const sandboxStartupGateEnv = "GOBOT_SANDBOX_STARTUP_GATE"

func TestExecutorCancelsProcessTree(t *testing.T) { //nolint:paralleltest // manipulates inherited helper env and process tree state
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	helper := sandboxProcessTreeHelper(t, ctx, Config{SandboxRoot: t.TempDir()})

	grandchildPID := waitForHelperPID(t, helper)
	cancel()
	waitForProcessExit(t, grandchildPID, 5*time.Second)
	helper.wait(t, "Run after cancellation")
}

func TestExecutorTimeoutKillsProcessTree(t *testing.T) { //nolint:paralleltest // manipulates inherited helper env and process tree state
	timeoutFactory, expire := controlledTreeTimeout(t)
	helper := sandboxProcessTreeHelper(t, context.Background(), Config{
		SandboxRoot: t.TempDir(), Timeout: time.Hour,
	}, timeoutFactory)
	grandchildPID := waitForHelperPID(t, helper)
	expire()
	waitForProcessExit(t, grandchildPID, 5*time.Second)
	helper.wait(t, "Run after configured timeout")
}

func TestExecutorProcessTreeStartupConsumesTimeout(t *testing.T) { //nolint:paralleltest // inherited helper env
	gate := filepath.Join(t.TempDir(), "startup")
	t.Setenv(sandboxStartupGateEnv, gate)
	timeoutFactory, expire := controlledTreeTimeout(t)
	helper := sandboxProcessTreeHelper(t, context.Background(), Config{
		SandboxRoot: t.TempDir(), Timeout: time.Hour,
	}, timeoutFactory)
	waitForStartupEntry(t, helper, gate+".entered")
	expire()
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

	runner := New(Config{
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

func sandboxProcessTreeHelper(t *testing.T, ctx context.Context, cfg Config, timeoutFactory ...func(context.Context, time.Duration) (context.Context, context.CancelFunc)) *treeHelper {
	t.Helper()
	t.Setenv(sandboxHelperEnv, "1")

	pidFile := t.TempDir() + `\grandchild.pid`
	ctx, cancel := context.WithCancel(ctx)
	helper := &treeHelper{pidFile: pidFile, done: make(chan struct{}), started: time.Now()}
	runner := New(cfg)
	if len(timeoutFactory) > 0 {
		runner.(*winExecutor).withTimeout = timeoutFactory[0]
	}
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
	if gate := os.Getenv(sandboxStartupGateEnv); gate != "" {
		if err := os.WriteFile(gate+".entered", []byte("entered"), 0o600); err != nil { //nolint:gosec // parent-owned helper gate path
			os.Exit(2)
		}
		for {
			if _, err := os.Stat(gate + ".release"); err == nil { //nolint:gosec // parent-owned helper gate path
				break
			}
			time.Sleep(10 * time.Millisecond) // Poll an explicit parent-owned gate.
		}
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

func waitForStartupEntry(t *testing.T, helper *treeHelper, path string) {
	t.Helper()
	watchdog := time.NewTimer(treeWaitBound(t, 30*time.Second, false))
	defer watchdog.Stop()
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	for {
		if _, err := os.Stat(path); err == nil {
			return
		}
		select {
		case <-helper.done:
			t.Fatalf("helper exited before startup gate: %v", helper.result.err)
		case <-watchdog.C:
			t.Fatal("helper never entered startup gate")
		case <-ticker.C:
		}
	}
}

// A controlled timeout retains parent cancellation and reports deadline expiry.
type treeTimeoutContext struct{ context.Context }

func (c treeTimeoutContext) Err() error {
	if errors.Is(context.Cause(c.Context), context.DeadlineExceeded) {
		return context.DeadlineExceeded
	}
	return c.Context.Err()
}
func controlledTreeTimeout(t *testing.T) (factory func(context.Context, time.Duration) (context.Context, context.CancelFunc), expire context.CancelFunc) {
	t.Helper()
	trigger, expire := context.WithCancel(context.Background())
	t.Cleanup(expire)
	factory = func(parent context.Context, timeout time.Duration) (context.Context, context.CancelFunc) {
		if timeout != time.Hour {
			t.Errorf("timeout=%v, want 1h", timeout)
		}
		ctx, cancel := context.WithCancelCause(parent)
		stop := context.AfterFunc(trigger, func() { cancel(context.DeadlineExceeded) })
		return treeTimeoutContext{ctx}, func() { stop(); cancel(context.Canceled) }
	}
	return factory, expire
}
