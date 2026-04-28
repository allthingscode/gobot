//nolint:testpackage // intentionally uses unexported helpers from main package
package app

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/sandbox"
)

type mockExecutor struct {
	capturedName string
	capturedArgs []string
	output       string
	err          error
}

func (m *mockExecutor) Run(_ context.Context, name string, args []string) (string, error) {
	m.capturedName = name
	m.capturedArgs = args
	return m.output, m.err
}

func TestShellExecTool_Name(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	tool := newShellExecTool(cfg, 2*time.Minute, nil)
	if got := tool.Name(); got != "shell_exec" {
		t.Errorf("Name() = %q, want %q", got, "shell_exec")
	}
}

//nolint:funlen // table-driven coverage for shell_exec behaviors
func TestShellExecTool_Execute(t *testing.T) {
	t.Parallel()
	ctx := context.Background()

	tests := []struct {
		name       string
		args       map[string]any
		mockOutput string
		mockErr    error
		wantErr    bool
		wantOutput string // Substring to match; if empty, checking is skipped.
		wantSuffix string // expected suffix; empty = skip
		wantArgs   []string
	}{
		{
			name:    "missing_command",
			args:    map[string]any{},
			wantErr: true,
		},
		{
			name: "go_requires_subcommand",
			args: map[string]any{
				"command": "go",
			},
			wantErr: true,
		},
		{
			name:       "propagates_output",
			args:       map[string]any{"command": "cmd"},
			mockOutput: "hello\n",
			wantOutput: "hello\n",
		},
		{
			name:       "truncates_long_output",
			args:       map[string]any{"command": "cmd"},
			mockOutput: strings.Repeat("x", 5000),
			wantSuffix: "[output truncated]",
		},
		{
			name:    "propagates_error",
			args:    map[string]any{"command": "cmd"},
			mockErr: errors.New("boom"),
			wantErr: true,
		},
		{
			name: "extracts_args",
			args: map[string]any{
				"command": "cmd",
				"args":    []any{"a", "b"},
			},
			wantArgs: []string{"a", "b"},
		},
		{
			name: "cwd_in_workspace",
			args: map[string]any{
				"command": "cmd",
				"cwd":     "subdir",
			},
			mockOutput: "hello",
			wantOutput: "hello",
		},
		{
			name: "cwd_outside_forbidden",
			args: map[string]any{
				"command": "cmd",
				"cwd":     "../../windows",
			},
			wantErr: true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			mock := &mockExecutor{output: tc.mockOutput, err: tc.mockErr}
			cfg := &config.Config{}
			cfg.Strategic.StorageRoot = t.TempDir()
			tool := &shellExecTool{
				cfg:     cfg,
				newExec: func(sandbox.Config) sandbox.Executor { return mock },
			}

			output, err := tool.Execute(ctx, "test-session", "", tc.args)
			validateShellExecResult(t, tc, output, err, mock)
		})
	}
}

func validateShellExecResult(t *testing.T, tc struct {
	name       string
	args       map[string]any
	mockOutput string
	mockErr    error
	wantErr    bool
	wantOutput string
	wantSuffix string
	wantArgs   []string
}, output string, err error, mock *mockExecutor) {
	t.Helper()
	if tc.wantErr && err == nil {
		t.Errorf("expected error, got nil")
	}
	if !tc.wantErr && err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	if tc.wantOutput != "" && output != tc.wantOutput {
		t.Errorf("output = %q, want %q", output, tc.wantOutput)
	}
	if tc.wantSuffix != "" && !strings.HasSuffix(output, tc.wantSuffix) {
		t.Errorf("output %q does not end with %q", output, tc.wantSuffix)
	}
	if tc.wantArgs != nil {
		validateShellArgs(t, tc.wantArgs, mock.capturedArgs)
	}
}

func validateShellArgs(t *testing.T, want, got []string) {
	t.Helper()
	if len(got) != len(want) {
		t.Errorf("capturedArgs = %v, want %v", got, want)
		return
	}
	for i, a := range want {
		if got[i] != a {
			t.Errorf("capturedArgs[%d] = %q, want %q", i, got[i], a)
		}
	}
}
