//go:build !windows

// On non-Windows platforms, commands run via os/exec with working-directory
// and timeout constraints. Resource limits (memory, CPU) are not enforced
// because Windows Job Objects are unavailable; see docs/architecture.md.

package sandbox

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
)

// New creates a functional Executor for non-Windows platforms.
// NOTE: MaxMemoryMB and MaxCPUSec limits are silently ignored; only Timeout
// and SandboxRoot are enforced on this platform.
func New(cfg Config) Executor {
	return &unixExecutor{cfg: cfg}
}

type unixExecutor struct {
	cfg Config
}

// Run executes name with args in cfg.SandboxRoot, capturing combined stdout
// and stderr. Timeout is enforced via the context. On error the partial output
// captured before the failure is returned alongside the error.
func (e *unixExecutor) Run(ctx context.Context, name string, args []string) (string, error) {
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

	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = sandboxDir
	var outBuf bytes.Buffer
	cmd.Stdout = &outBuf
	cmd.Stderr = &outBuf

	if err := cmd.Run(); err != nil {
		return outBuf.String(), fmt.Errorf("sandbox: run: %w", err)
	}
	return outBuf.String(), nil
}
