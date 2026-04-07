//go:build windows

package sandbox

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

// New creates an Executor backed by Windows Job Objects.
func New(cfg Config) Executor {
	return &winExecutor{cfg: cfg}
}

type winExecutor struct {
	cfg Config
}

// Run starts name with args inside a Windows Job Object with the configured limits.
// The child process runs with SandboxRoot as its working directory.
// CREATE_SUSPENDED ensures the process is assigned to the Job Object before it executes.
func (e *winExecutor) Run(ctx context.Context, name string, args []string) (string, error) {
	if e.cfg.Timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, e.cfg.Timeout)
		defer cancel()
	}

	sandboxDir := e.cfg.SandboxRoot
	if sandboxDir == "" {
		sandboxDir = os.TempDir()
	}
	if err := os.MkdirAll(sandboxDir, 0o755); err != nil {
		return "", fmt.Errorf("sandbox: mkdir %s: %w", sandboxDir, err)
	}

	// Create the Job Object that will contain the child process.
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return "", fmt.Errorf("sandbox: CreateJobObject: %w", err)
	}
	defer func() { _ = windows.CloseHandle(job) }()

	if err := applyJobLimits(job, e.cfg); err != nil {
		return "", fmt.Errorf("sandbox: applyJobLimits: %w", err)
	}

	// Start the process SUSPENDED so we can assign it to the Job Object
	// before it executes any user code.
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = sandboxDir
	cmd.SysProcAttr = &syscall.SysProcAttr{
		CreationFlags: windows.CREATE_SUSPENDED | windows.CREATE_NEW_PROCESS_GROUP,
	}
	var outBuf bytes.Buffer
	cmd.Stdout = &outBuf
	cmd.Stderr = &outBuf

	if err := cmd.Start(); err != nil {
		return "", fmt.Errorf("sandbox: start: %w", err)
	}

	// F-102: Start a monitor goroutine to ensure the Job Object is terminated
	// if the context is cancelled. exec.CommandContext kills the direct child,
	// but on Windows, cmd.Wait() will hang forever if grandchildren keep pipes
	// open. Terminating the Job Object kills the whole tree and closes the pipes.
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-ctx.Done():
			// Context cancelled or timed out — kill the whole job tree immediately.
			_ = windows.TerminateJobObject(job, 1)
		case <-done:
			// Run finished naturally.
		}
	}()

	// Open a handle to the child process by PID and assign it to the Job Object.
	pid := cmd.Process.Pid
	if pid < 0 {
		_ = cmd.Process.Kill()
		return "", fmt.Errorf("sandbox: invalid PID: %d", pid)
	}
	ph, err := windows.OpenProcess(windows.PROCESS_ALL_ACCESS, false, uint32(pid)) // #nosec G115
	if err != nil {
		_ = cmd.Process.Kill()
		return "", fmt.Errorf("sandbox: OpenProcess: %w", err)
	}
	defer func() { _ = windows.CloseHandle(ph) }()

	if err := windows.AssignProcessToJobObject(job, ph); err != nil {
		_ = cmd.Process.Kill()
		return "", fmt.Errorf("sandbox: AssignProcessToJobObject: %w", err)
	}

	// Find the main thread of the child process and resume it.
	// #nosec G115 - PID is checked to be non-negative.
	if err := resumeMainThread(uint32(pid)); err != nil {
		_ = cmd.Process.Kill()
		return "", fmt.Errorf("sandbox: resumeMainThread: %w", err)
	}

	if err := cmd.Wait(); err != nil {
		// Return any captured output alongside the error for diagnostics.
		return outBuf.String(), fmt.Errorf("sandbox: wait: %w", err)
	}
	return outBuf.String(), nil
}

// applyJobLimits sets resource limits on job using JOBOBJECT_EXTENDED_LIMIT_INFORMATION.
// JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE is always set so child processes are killed
// when the Job Object handle is closed (deferred in Run).
func applyJobLimits(job windows.Handle, cfg Config) error {
	var info windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION
	var flags uint32 = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE

	if cfg.MaxMemoryMB > 0 {
		info.ProcessMemoryLimit = uintptr(cfg.MaxMemoryMB * 1024 * 1024)
		flags |= windows.JOB_OBJECT_LIMIT_PROCESS_MEMORY
	}
	if cfg.MaxCPUSec > 0 {
		// PerProcessUserTimeLimit is in 100-nanosecond intervals.
		info.BasicLimitInformation.PerProcessUserTimeLimit = int64(cfg.MaxCPUSec * 1e7)
		flags |= windows.JOB_OBJECT_LIMIT_PROCESS_TIME
	}
	info.BasicLimitInformation.LimitFlags = flags

	_, err := windows.SetInformationJobObject(
		job,
		uint32(windows.JobObjectExtendedLimitInformation),
		uintptr(unsafe.Pointer(&info)),
		uint32(unsafe.Sizeof(info)),
	)
	if err != nil {
		return fmt.Errorf("SetInformationJobObject: %w", err)
	}
	return nil
}

// resumeMainThread enumerates all system threads to find the first thread belonging
// to pid, then calls ResumeThread on it.
func resumeMainThread(pid uint32) error {
	snap, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPTHREAD, 0)
	if err != nil {
		return fmt.Errorf("CreateToolhelp32Snapshot: %w", err)
	}
	defer func() { _ = windows.CloseHandle(snap) }()

	var te windows.ThreadEntry32
	te.Size = uint32(unsafe.Sizeof(te))
	if err := windows.Thread32First(snap, &te); err != nil {
		return fmt.Errorf("Thread32First: %w", err)
	}
	for {
		if te.OwnerProcessID == pid {
			th, err := windows.OpenThread(windows.THREAD_SUSPEND_RESUME, false, te.ThreadID)
			if err != nil {
				return fmt.Errorf("OpenThread: %w", err)
			}
			_, resumeErr := windows.ResumeThread(th)
			_ = windows.CloseHandle(th)
			if resumeErr != nil {
				return fmt.Errorf("ResumeThread: %w", resumeErr)
			}
			return nil
		}
		if err := windows.Thread32Next(snap, &te); err != nil {
			if errors.Is(err, windows.ERROR_NO_MORE_FILES) {
				break
			}
			return fmt.Errorf("Thread32Next: %w", err)
		}
	}
	return fmt.Errorf("no thread found for PID %d", pid)
}
