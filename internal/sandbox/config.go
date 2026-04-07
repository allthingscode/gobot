// Package sandbox provides sandboxed subprocess execution using Windows Job Objects.
package sandbox

import (
	"context"
	"time"
)

// Config holds resource limits and directory constraints for sandboxed execution.
type Config struct {
	// MaxMemoryMB is the maximum per-process commit charge in megabytes. 0 = no limit.
	MaxMemoryMB uint64
	// MaxCPUSec is the maximum per-process CPU time in seconds. 0 = no limit.
	MaxCPUSec float64
	// SandboxRoot is the working directory for child processes. Empty = os.TempDir().
	SandboxRoot string
	// Timeout is the wall-clock deadline for each Run call. 0 = no timeout.
	Timeout time.Duration
}

// Executor runs commands in a sandboxed environment.
type Executor interface {
	// Run executes name with args, returning combined stdout+stderr output.
	// On non-Windows platforms resource limits are not enforced; only Timeout
	// and SandboxRoot are applied.
	Run(ctx context.Context, name string, args []string) (output string, err error)
}
