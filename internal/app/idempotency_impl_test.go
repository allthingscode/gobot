//nolint:testpackage // requires internal types for testing
package app

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

const (
	testSessionKey = "test-session"
	
	// Constants for platform detection to avoid magic strings.
	windowsOS      = "windows"
	cmdExecutor    = "cmd"
	shExecutor     = "sh"
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
	tool := newShellExecTool(workspace, 10*time.Second, registry)

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
		"command": cmd,
		"args":    cmdArgs,
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
		"command": cmd,
		"args":    cmdArgs,
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
		"command": cmd,
		"args":    cmdArgs,
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
	
	tool := newSendEmailTool(t.TempDir(), t.TempDir(), "user@example.com", registry, nil)
	
	args := map[string]any{
		"subject": "Hello",
		"body": "World",
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
