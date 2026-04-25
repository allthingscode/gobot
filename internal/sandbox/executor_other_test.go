//go:build !windows

package sandbox_test

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/sandbox"
)

func TestExecutor_Unix(t *testing.T) {
	t.Parallel()
	ctx := context.Background()

	tests := []struct {
		name         string
		cfg          sandbox.Config
		cmd          string
		args         []string
		wantErr      bool
		wantInOutput string
	}{
		{
			name:         "echo_command",
			cfg:          sandbox.Config{SandboxRoot: t.TempDir()},
			cmd:          "sh",
			args:         []string{"-c", "echo hello"},
			wantErr:      false,
			wantInOutput: "hello",
		},
		{
			name:    "bad_command",
			cfg:     sandbox.Config{SandboxRoot: t.TempDir()},
			cmd:     "nonexistent_cmd_xyz_abc",
			args:    nil,
			wantErr: true,
		},
		{
			name:    "timeout",
			cfg:     sandbox.Config{SandboxRoot: t.TempDir(), Timeout: 1 * time.Millisecond},
			cmd:     "sh",
			args:    []string{"-c", "sleep 5"},
			wantErr: true,
		},
		{
			name:         "output_on_error",
			cfg:          sandbox.Config{SandboxRoot: t.TempDir()},
			cmd:          "sh",
			args:         []string{"-c", "echo fail; exit 1"},
			wantErr:      true,
			wantInOutput: "fail",
		},
		{
			name:         "stderr_captured",
			cfg:          sandbox.Config{SandboxRoot: t.TempDir()},
			cmd:          "sh",
			args:         []string{"-c", "echo errout >&2"},
			wantErr:      false,
			wantInOutput: "errout",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			exec := sandbox.New(tc.cfg)
			output, err := exec.Run(ctx, tc.cmd, tc.args)
			if tc.wantErr && err == nil {
				t.Errorf("expected error, got nil (output: %q)", output)
			}
			if !tc.wantErr && err != nil {
				t.Errorf("unexpected error: %v (output: %q)", err, output)
			}
			if tc.wantInOutput != "" && !strings.Contains(output, tc.wantInOutput) {
				t.Errorf("output %q does not contain %q", output, tc.wantInOutput)
			}
		})
	}
}

func TestExecutor_WorkingDirectory_Unix(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()

	// Write a sentinel file into the sandbox dir; verify it is visible from the subprocess.
	sentinel := "gobot_sandbox_sentinel.txt"
	if err := os.WriteFile(filepath.Join(dir, sentinel), []byte("ok"), 0o600); err != nil {
		t.Fatalf("write sentinel: %v", err)
	}

	cfg := sandbox.Config{SandboxRoot: dir}
	exec := sandbox.New(cfg)
	output, err := exec.Run(context.Background(), "sh", []string{"-c", "ls"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(output, sentinel) {
		t.Errorf("expected sentinel %q in ls output %q; working directory not applied", sentinel, output)
	}
}

func TestExecutor_DefaultSandboxRoot(t *testing.T) {
	t.Parallel()
	// SandboxRoot="" should default to os.TempDir() without error.
	cfg := sandbox.Config{}
	exec := sandbox.New(cfg)
	output, err := exec.Run(context.Background(), "sh", []string{"-c", "echo ok"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(output, "ok") {
		t.Errorf("output %q does not contain %q", output, "ok")
	}
}
