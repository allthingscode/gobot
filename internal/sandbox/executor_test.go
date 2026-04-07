//go:build windows

package sandbox_test

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/sandbox"
)

func TestExecutor(t *testing.T) {
	t.Parallel()
	ctx := context.Background()

	tests := []struct {
		name         string
		cfg          sandbox.Config
		cmd          string
		args         []string
		wantErr      bool
		wantInOutput string // substring; empty = skip output check
	}{
		{
			name:         "echo_command",
			cfg:          sandbox.Config{SandboxRoot: t.TempDir()},
			cmd:          "cmd",
			args:         []string{"/c", "echo hello"},
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
			cmd:     "cmd",
			args:    []string{"/c", "ping -n 5 127.0.0.1"},
			wantErr: true,
		},
		{
			name:         "output_on_error",
			cfg:          sandbox.Config{SandboxRoot: t.TempDir()},
			cmd:          "cmd",
			args:         []string{"/c", "echo fail & exit /b 1"},
			wantErr:      true,
			wantInOutput: "fail",
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

func TestExecutor_WorkingDirectory(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	cfg := sandbox.Config{SandboxRoot: dir}
	exec := sandbox.New(cfg)
	output, err := exec.Run(context.Background(), "cmd", []string{"/c", "cd"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// On Windows, cd might return short path or casing differences, but prefix check is generally safe for TempDir
	if !strings.HasPrefix(strings.ToLower(strings.TrimSpace(output)), strings.ToLower(dir)) {
		t.Errorf("working dir: got %q, want prefix %q", strings.TrimSpace(output), dir)
	}
}
