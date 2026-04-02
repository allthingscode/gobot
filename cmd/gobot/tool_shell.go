package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"time"

	"github.com/allthingscode/gobot/internal/provider"
	"github.com/allthingscode/gobot/internal/sandbox"
	"github.com/allthingscode/gobot/internal/shell"
)

const (
	shellExecToolName = "shell_exec"
	shellMaxOutput    = 4096
)

// shellExecTool exposes sandboxed shell command execution to the agent.
// Commands run inside a Windows Job Object with memory and CPU limits.
type shellExecTool struct {
	exec          sandbox.Executor
	workspaceRoot string
	projectRoot   string
}

// newShellExecTool creates a shellExecTool rooted in sandboxRoot.
// Default limits: 512 MB per-process memory, 30 s CPU, wall-clock timeout as configured.
func newShellExecTool(workspaceRoot string, timeout time.Duration) *shellExecTool {
	cfg := sandbox.Config{
		MaxMemoryMB: 512,
		MaxCPUSec:   30.0,
		SandboxRoot: workspaceRoot,
		Timeout:     timeout,
	}
	// Try to determine project root (e.g. C:\Users\...\Documents\gobot)
	projectRoot, _ := os.Getwd()
	return &shellExecTool{
		exec:          sandbox.New(cfg),
		workspaceRoot: workspaceRoot,
		projectRoot:   projectRoot,
	}
}

func (t *shellExecTool) Name() string { return shellExecToolName }

func (t *shellExecTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        shellExecToolName,
		Description: "Execute a shell command in a sandboxed Windows environment. Working directory is the bot workspace. Output is capped at 4096 characters.",
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"command": map[string]any{
					"type":        "string",
					"description": "Executable to run (e.g. 'cmd', 'powershell', 'python').",
				},
				"args": map[string]any{
					"type":        "array",
					"description": "Arguments to pass to the command.",
					"items": map[string]any{
						"type": "string",
					},
				},
			},
			"required": []string{"command"},
		},
	}
}

func (t *shellExecTool) Execute(ctx context.Context, sessionKey string, args map[string]any) (string, error) {
	cmd, _ := args["command"].(string)
	if cmd == "" {
		return "", errors.New("shell_exec: command is required")
	}

	// Always redirect C:\ paths in the command itself if it looks like a script/command
	cmd = shell.RedirectCDrive(cmd, t.workspaceRoot, t.projectRoot)

	var cmdArgs []string
	if rawArgs, ok := args["args"].([]any); ok {
		for _, a := range rawArgs {
			if s, ok := a.(string); ok {
				// Redirect C:\ paths in each argument
				redirected := shell.RedirectCDrive(s, t.workspaceRoot, t.projectRoot)
				cmdArgs = append(cmdArgs, redirected)
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
