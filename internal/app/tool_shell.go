package app

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"time"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/provider"
	"github.com/allthingscode/gobot/internal/sandbox"
	"github.com/allthingscode/gobot/internal/shell"
)

const (
	shellExecToolName = "shell_exec"
	shellMaxOutput    = 4096
)

type shellExecArgs struct {
	Command     string   `json:"command" schema:"Executable to run (e.g. 'cmd', 'powershell', 'python')."`
	Args        []string `json:"args,omitempty" schema:"Arguments to pass to the command."`
	ExecutionID string   `json:"execution_id,omitempty" schema:"Optional unique ID for this execution to ensure idempotency across session resumes."`
}

// shellExecTool exposes sandboxed shell command execution to the agent.
// Commands run inside a Windows Job Object with memory and CPU limits.
type shellExecTool struct {
	exec          sandbox.Executor
	workspaceRoot string
	projectRoot   string
	registry      *ToolRegistry // C-184: idempotency
}

// newShellExecTool creates a shellExecTool rooted in sandboxRoot.
// Default limits: 512 MB per-process memory, 30 s CPU, wall-clock timeout as configured.
func newShellExecTool(workspaceRoot string, timeout time.Duration, registry *ToolRegistry) *shellExecTool {
	cfg := sandbox.Config{
		MaxMemoryMB: 512,
		MaxCPUSec:   30.0,
		SandboxRoot: workspaceRoot,
		Timeout:     timeout,
	}
	// Try to determine project root base name (e.g. "gobot")
	wd, _ := os.Getwd()
	projectRoot := filepath.Base(wd)
	return &shellExecTool{
		exec:          sandbox.New(cfg),
		workspaceRoot: workspaceRoot,
		projectRoot:   projectRoot,
		registry:      registry,
	}
}

func (t *shellExecTool) Name() string { return shellExecToolName }

func (t *shellExecTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:          shellExecToolName,
		Description:   "Execute a shell command in a sandboxed environment. Working directory is the bot workspace. Output is capped at 4096 characters.",
		SideEffecting: true,
		Parameters:    agent.DeriveSchema(shellExecArgs{}),
	}
}

func (t *shellExecTool) Execute(ctx context.Context, sessionKey, userID string, args map[string]any) (string, error) {
	cmd, _ := args["command"].(string)
	if cmd == "" {
		return "", errors.New("shell_exec: command is required")
	}

	executionID, _ := args["execution_id"].(string)
	if result, hit := t.checkIdempotency(sessionKey, executionID); hit {
		return result, nil
	}

	// Always redirect absolute Windows system drive paths in the command itself
	// if it looks like a script/command
	cmd = shell.RedirectCDrive(cmd, t.workspaceRoot, t.projectRoot)

	var cmdArgs []string
	if rawArgs, ok := args["args"].([]any); ok {
		cmdArgs = t.prepareArgs(rawArgs)
	}

	slog.Info("shell_exec: running command", "session", sessionKey, "cmd", cmd, "args", cmdArgs)
	output, err := t.exec.Run(ctx, cmd, cmdArgs)
	if err != nil {
		return output, fmt.Errorf("shell_exec: %w", err)
	}

	if len(output) > shellMaxOutput {
		output = output[:shellMaxOutput] + "\n[output truncated]"
	}

	t.storeIdempotency(sessionKey, executionID, output)

	return output, nil
}

func (t *shellExecTool) checkIdempotency(sessionKey, executionID string) (string, bool) {
	if executionID != "" && t.registry != nil {
		if result, ok := t.registry.Check(sessionKey, executionID); ok {
			slog.Info("shell_exec: idempotency hit", "session", sessionKey, "execution_id", executionID)
			return result, true
		}
	}
	return "", false
}

func (t *shellExecTool) storeIdempotency(sessionKey, executionID, result string) {
	if executionID != "" && t.registry != nil {
		if storeErr := t.registry.Store(sessionKey, executionID, result); storeErr != nil {
			slog.Warn("shell_exec: failed to store idempotency result", "err", storeErr)
		}
	}
}

func (t *shellExecTool) prepareArgs(rawArgs []any) []string {
	var cmdArgs []string
	for _, a := range rawArgs {
		if s, ok := a.(string); ok {
			// Redirect absolute Windows system drive paths in each argument
			redirected := shell.RedirectCDrive(s, t.workspaceRoot, t.projectRoot)
			cmdArgs = append(cmdArgs, redirected)
		}
	}
	return cmdArgs
}
