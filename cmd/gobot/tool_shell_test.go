package main

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
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
	tool := newShellExecTool(t.TempDir(), 2*time.Minute)
	if got := tool.Name(); got != "shell_exec" {
		t.Errorf("Name() = %q, want %q", got, "shell_exec")
	}
}

func TestShellExecTool_Execute(t *testing.T) {
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
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			mock := &mockExecutor{output: tc.mockOutput, err: tc.mockErr}
			tool := &shellExecTool{exec: mock}

			output, err := tool.Execute(ctx, "test-session", tc.args)

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
				if len(mock.capturedArgs) != len(tc.wantArgs) {
					t.Errorf("capturedArgs = %v, want %v", mock.capturedArgs, tc.wantArgs)
				} else {
					for i, a := range tc.wantArgs {
						if mock.capturedArgs[i] != a {
							t.Errorf("capturedArgs[%d] = %q, want %q", i, mock.capturedArgs[i], a)
						}
					}
				}
			}
		})
	}
}
