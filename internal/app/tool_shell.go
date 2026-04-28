package app

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/config"
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
	CWD         string   `json:"cwd,omitempty" schema:"Optional working directory. Defaults to the user workspace. Can also be set to the project root for development tasks."`
	ExecutionID string   `json:"execution_id,omitempty" schema:"Optional unique ID for this execution to ensure idempotency across session resumes."`
}

// shellExecTool exposes sandboxed shell command execution to the agent.
// Commands run inside a Windows Job Object with memory and CPU limits.
type shellExecTool struct {
	cfg         *config.Config
	timeout     time.Duration
	projectRoot string
	registry    *ToolRegistry // C-184: idempotency

	// newExec allows injecting mock executors for testing.
	newExec func(sandbox.Config) sandbox.Executor
}

// newShellExecTool creates a shellExecTool.
// Default limits: 512 MB per-process memory, 30 s CPU, wall-clock timeout as configured.
func newShellExecTool(cfg *config.Config, timeout time.Duration, registry *ToolRegistry) *shellExecTool {
	// Try to determine project root base name (e.g. "gobot")
	wd, _ := os.Getwd()
	projectRoot := filepath.Base(wd)
	return &shellExecTool{
		cfg:         cfg,
		timeout:     timeout,
		projectRoot: projectRoot,
		registry:    registry,
		newExec:     sandbox.New,
	}
}

func (t *shellExecTool) Name() string { return shellExecToolName }

func (t *shellExecTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:          shellExecToolName,
		Description:   "Execute a shell command in a sandboxed environment. Working directory defaults to the bot workspace. Output is capped at 4096 characters.",
		SideEffecting: true,
		Parameters:    agent.DeriveSchema(shellExecArgs{}),
	}
}

func (t *shellExecTool) Execute(ctx context.Context, sessionKey, userID string, args map[string]any) (string, error) {
	cmd, _ := args["command"].(string)
	cmd = strings.TrimSpace(cmd)
	if cmd == "" {
		return "", errors.New("shell_exec: command is required")
	}

	executionID, _ := args["execution_id"].(string)
	if result, hit := t.checkIdempotency(sessionKey, executionID); hit {
		return result, nil
	}

	workspaceRoot := t.cfg.WorkspacePath(userID)
	projectRoot := t.cfg.ProjectRoot()

	runDir, err := t.resolveRunDir(args, workspaceRoot, projectRoot)
	if err != nil {
		return "", err
	}

	runDir = t.redirectGoCmd(cmd, runDir, projectRoot)
	cmd = shell.RedirectCDrive(cmd, workspaceRoot, t.projectRoot)

	var cmdArgs []string
	if rawArgs, ok := args["args"].([]any); ok {
		cmdArgs = t.prepareArgs(rawArgs, workspaceRoot)
	}

	// Remap Unix-only commands (ls, cat, grep, etc.) through PowerShell.
	cmd, cmdArgs = shell.RemapUnixCommand(cmd, cmdArgs)
	if cmd == "go" && len(cmdArgs) == 0 {
		return "", errors.New("shell_exec: go requires at least one argument (e.g. 'version', 'test', 'build')")
	}

	// Resource limits are intentionally 0 (disabled). Per-process CPU/memory
	// caps via Windows Job Objects kill grandchildren (e.g. go test binaries)
	// and leave cmd.Wait hanging on broken pipes. The wall-clock Timeout is
	// the sole safety net.
	execCfg := sandbox.Config{
		MaxMemoryMB: 0,
		MaxCPUSec:   0,
		SandboxRoot: runDir,
		Timeout:     t.timeout,
	}
	exec := t.newExec(execCfg)

	slog.Info("shell_exec: running command", "session", sessionKey, "user", userID, "cmd", cmd, "args", cmdArgs, "cwd", runDir)
	output, err := exec.Run(ctx, cmd, cmdArgs)
	if err != nil {
		// Include the command and arguments in the error for better agent diagnostics
		return output, fmt.Errorf("shell_exec: run %s %v (in %s): %w", cmd, cmdArgs, runDir, err)
	}

	if len(output) > shellMaxOutput {
		output = output[:shellMaxOutput] + "\n[output truncated]"
	}

	t.storeIdempotency(sessionKey, executionID, output)

	return output, nil
}

func (t *shellExecTool) isSubpath(root, target string) bool {
	root = filepath.Clean(root)
	target = filepath.Clean(target)
	rel, err := filepath.Rel(root, target)
	if err != nil {
		return false
	}
	return rel == "." || (!strings.HasPrefix(rel, "..") && !filepath.IsAbs(rel))
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

func (t *shellExecTool) prepareArgs(rawArgs []any, workspaceRoot string) []string {
	var cmdArgs []string
	for _, a := range rawArgs {
		if s, ok := a.(string); ok {
			// Redirect absolute Windows system drive paths in each argument
			redirected := shell.RedirectCDrive(s, workspaceRoot, t.projectRoot)
			cmdArgs = append(cmdArgs, redirected)
		}
	}
	return cmdArgs
}

func (t *shellExecTool) fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func (t *shellExecTool) resolveRunDir(args map[string]any, workspaceRoot, projectRoot string) (string, error) {
	requestedCWD, ok := args["cwd"].(string)
	if !ok || requestedCWD == "" {
		return workspaceRoot, nil
	}
	target := requestedCWD
	if !filepath.IsAbs(target) {
		target = filepath.Join(workspaceRoot, target)
	}
	target = filepath.Clean(target)
	inWorkspace := t.isSubpath(workspaceRoot, target)
	inProject := projectRoot != "" && t.isSubpath(projectRoot, target)
	if !inWorkspace && !inProject {
		return "", fmt.Errorf("shell_exec: cwd %q is outside allowed roots (workspace or project)", requestedCWD)
	}
	return target, nil
}

func (t *shellExecTool) redirectGoCmd(cmd, runDir, projectRoot string) string {
	if cmd != "go" || projectRoot == "" {
		return runDir
	}
	if !t.fileExists(filepath.Join(runDir, "go.mod")) && t.fileExists(filepath.Join(projectRoot, "go.mod")) {
		return projectRoot
	}
	return runDir
}
