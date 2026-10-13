//nolint:testpackage // requires internal types for testing
package app

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"golang.org/x/time/rate"
)

//nolint:paralleltest // Checkpoint manager cleanup uses process-wide test state.
func TestRunner_ExplicitExecutionIDFreshTurns(t *testing.T) {
	mgr, err := agentctx.GetCheckpointManager(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(agentctx.ResetCheckpointManagerInstancesForTest)
	registry := NewToolRegistry(t.TempDir())
	visits, effects := 0, 0
	tool := stateCheckingTool{name: "explicit_write", run: func(_ context.Context, session, _ string, args map[string]any) (string, error) {
		visits++
		id := args["execution_id"].(string)
		if result, found := registry.Check(session, id); found {
			return result, nil
		}
		effects++
		result := fmt.Sprintf("effect-%d", effects)
		if err := registry.Store(session, id, result); err != nil {
			return "", fmt.Errorf("store fake effect: %w", err)
		}
		return result, nil
	}}
	r := NewAgentRunner(&MockProvider{}, testModel, basePrompt, &config.Config{})
	r.Limiter = rate.NewLimiter(rate.Inf, 1)
	r.SetTools([]Tool{tool})
	r.SideEffectingTools[tool.name] = true
	r.IdempStore = agentctx.NewIdempotencyStore(mgr.DB(), time.Hour)
	for _, tc := range []struct {
		id, want string
	}{
		{"explicit-1", "effect-1"},
		{"explicit-1", "effect-1"},
		{"explicit-2", "effect-2"},
	} {
		messages := runAutomaticToolTurn(t, context.Background(), r, []agentctx.ToolCall{{
			ID: "same-provider-id", Name: tool.name, Args: map[string]any{"execution_id": tc.id},
		}})
		if got := ExtractText(messages[2]); got != tc.want {
			t.Fatalf("execution_id %s: got %q, want %q", tc.id, got, tc.want)
		}
	}
	if visits != 3 || effects != 2 {
		t.Fatalf("registry visits=%d, effects=%d; want 3 and 2", visits, effects)
	}
}

const (
	testSessionKey = "test-session"

	// Constants for platform detection to avoid magic strings.
	windowsOS   = "windows"
	cmdExecutor = "cmd"
	shExecutor  = "sh"
)

func TestToolRegistry_Idempotency(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	registry := NewToolRegistry(tmpDir)
	sessionKey := testSessionKey

	execID := "exec-1"
	result := "success"

	// 1. Check miss
	if _, ok := registry.Check(sessionKey, execID); ok {
		t.Fatal("expected miss for new execution ID")
	}

	// 2. Store
	if err := registry.Store(sessionKey, execID, result); err != nil {
		t.Fatalf("Store failed: %v", err)
	}

	// 3. Check hit
	got, ok := registry.Check(sessionKey, execID)
	if !ok {
		t.Fatal("expected hit for stored execution ID")
	}
	if got != result {
		t.Errorf("got %q, want %q", got, result)
	}

	// 4. Verify file exists
	regPath := filepath.Join(tmpDir, sessionKey, "tool_registry.json")
	if _, err := os.Stat(regPath); os.IsNotExist(err) {
		t.Fatal("registry file not created")
	}
	registryJSON, err := os.ReadFile(regPath)
	if err != nil {
		t.Fatalf("read registry file: %v", err)
	}
	if !bytes.HasSuffix(registryJSON, []byte("\n")) {
		t.Fatalf("registry JSON missing trailing newline: %q", registryJSON)
	}
	var persisted toolRegistryData
	if err := json.Unmarshal(registryJSON, &persisted); err != nil {
		t.Fatalf("unmarshal registry file: %v", err)
	}
	if persisted.Executions[execID] != result {
		t.Fatalf("persisted execution = %q, want %q", persisted.Executions[execID], result)
	}
}

func TestShellExecTool_Idempotency(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	registry := NewToolRegistry(tmpDir)
	sessionKey := testSessionKey
	userID := "user-1"

	// Using a tool that we can easily verify execution
	// But since we are testing idempotency, we just need to see if it returns cached result.

	// Create a dummy workspace
	workspace := t.TempDir()
	cfg := &config.Config{}
	cfg.Runtime.StorageRoot = workspace
	tool := newShellExecTool(cfg, 10*time.Second, registry)

	execID := "unique-id-123"

	// First execution - use platform-appropriate command
	var cmd string
	var cmdArgs []any
	if runtime.GOOS == windowsOS {
		cmd = cmdExecutor
		cmdArgs = []any{"/c", "echo first"}
	} else {
		cmd = shExecutor
		cmdArgs = []any{"-c", "echo first"}
	}

	args1 := map[string]any{
		"command":      cmd,
		"args":         cmdArgs,
		"execution_id": execID,
	}

	resp1, err := tool.Execute(context.Background(), sessionKey, userID, args1)
	if err != nil {
		t.Fatalf("First Execute failed: %v", err)
	}

	// Second execution with SAME ID but DIFFERENT command
	if runtime.GOOS == windowsOS {
		cmd = cmdExecutor
		cmdArgs = []any{"/c", "echo second"}
	} else {
		cmd = shExecutor
		cmdArgs = []any{"-c", "echo second"}
	}

	args2 := map[string]any{
		"command":      cmd,
		"args":         cmdArgs,
		"execution_id": execID,
	}

	resp2, err := tool.Execute(context.Background(), sessionKey, userID, args2)
	if err != nil {
		t.Fatalf("Second Execute failed: %v", err)
	}

	if resp1 != resp2 {
		t.Errorf("Idempotency failed: resp1=%q, resp2=%q", resp1, resp2)
	}

	// Third execution with DIFFERENT ID
	if runtime.GOOS == windowsOS {
		cmd = cmdExecutor
		cmdArgs = []any{"/c", "echo third"}
	} else {
		cmd = shExecutor
		cmdArgs = []any{"-c", "echo third"}
	}

	args3 := map[string]any{
		"command":      cmd,
		"args":         cmdArgs,
		"execution_id": "different-id",
	}

	resp3, err := tool.Execute(context.Background(), sessionKey, userID, args3)
	if err != nil {
		t.Fatalf("Third Execute failed: %v", err)
	}

	if resp3 == resp1 {
		t.Errorf("Expected different result for different ID, but got SAME: %q", resp3)
	}
}

func TestSendEmailTool_Idempotency(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	registry := NewToolRegistry(tmpDir)
	sessionKey := testSessionKey

	// We can't easily mock google.Service here without more refactoring,
	// but we can test the registry check/store logic by manually pre-filling the registry.

	execID := "email-123"
	cachedResult := "Email sent to user@example.com: Hello (CACHED)"

	if err := registry.Store(sessionKey, execID, cachedResult); err != nil {
		t.Fatalf("Pre-fill failed: %v", err)
	}

	tool := newSendEmailTool(t.TempDir(), t.TempDir(), "user@example.com", registry, nil, nil)

	args := map[string]any{
		"subject":      "Hello",
		"body":         "World",
		"execution_id": execID,
	}

	resp, err := tool.Execute(context.Background(), sessionKey, "user-1", args)
	if err != nil {
		t.Fatalf("Execute failed: %v", err)
	}

	if resp != cachedResult {
		t.Errorf("got %q, want %q", resp, cachedResult)
	}
}
