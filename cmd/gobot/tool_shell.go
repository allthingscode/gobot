package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"google.golang.org/genai"

	"github.com/allthingscode/gobot/internal/sandbox"
)

const (
	shellExecToolName = "shell_exec"
	shellMaxOutput    = 4096
)

// shellExecTool exposes sandboxed shell command execution to the agent.
// Commands run inside a Windows Job Object with memory and CPU limits.
type shellExecTool struct {
	exec sandbox.Executor
}

// newShellExecTool creates a shellExecTool rooted in sandboxRoot.
// Default limits: 512 MB per-process memory, 30 s CPU, 2 min wall-clock timeout.
func newShellExecTool(sandboxRoot string) *shellExecTool {
	cfg := sandbox.Config{
		MaxMemoryMB: 512,
		MaxCPUSec:   30.0,
		SandboxRoot: sandboxRoot,
		Timeout:     2 * time.Minute,
	}
	return &shellExecTool{exec: sandbox.New(cfg)}
}

func (t *shellExecTool) Name() string { return shellExecToolName }

func (t *shellExecTool) Declaration() *genai.FunctionDeclaration {
	return &genai.FunctionDeclaration{
		Name:        shellExecToolName,
		Description: "Execute a shell command in a sandboxed Windows environment. Working directory is the bot workspace. Output is capped at 4096 characters.",
		Parameters: &genai.Schema{
			Type: genai.TypeObject,
			Properties: map[string]*genai.Schema{
				"command": {
					Type:        genai.TypeString,
					Description: "Executable to run (e.g. 'cmd', 'powershell', 'python').",
				},
				"args": {
					Type:        genai.TypeArray,
					Description: "Arguments to pass to the command.",
					Items:       &genai.Schema{Type: genai.TypeString},
				},
			},
			Required: []string{"command"},
		},
	}
}

func (t *shellExecTool) Execute(ctx context.Context, sessionKey string, args map[string]any) (string, error) {
	cmd, _ := args["command"].(string)
	if cmd == "" {
		return "", errors.New("shell_exec: command is required")
	}

	var cmdArgs []string
	if rawArgs, ok := args["args"].([]any); ok {
		for _, a := range rawArgs {
			if s, ok := a.(string); ok {
				cmdArgs = append(cmdArgs, s)
			}
		}
	}

	slog.Info("shell_exec: running command", "session", sessionKey, "cmd", cmd, "args", cmdArgs)
	output, err := t.exec.Run(ctx, cmd, cmdArgs)
	if err != nil {
		return output, fmt.Errorf("shell_exec: %w", err)
	}

	if len(output) > shellMaxOutput {
		output = output[:shellMaxOutput] + "\n[output truncated]"
	}
	return output, nil
}
