//nolint:testpackage // intentionally uses unexported helpers from main package
package app

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"
)

//nolint:paralleltest // depends on time.Now() and shared session folders in tmp
func TestSendEmailTool_CronIdempotency(t *testing.T) {
	// We don't use t.Parallel() because we might rely on time.Now()
	// although for this test we'll just check if it hits the registry.

	tmpDir := t.TempDir()
	registry := NewToolRegistry(tmpDir)

	// sessionKey for a cron job
	jobID := "morning_briefing"
	recipient := "user@example.com"
	sessionKey := fmt.Sprintf("cron:%s:email:%s", jobID, recipient)

	// The deterministic ID we EXPECT the tool to generate
	date := time.Now().Format("2006-01-02")
	autoExecID := fmt.Sprintf("scheduled_email_auto_%s", date)

	cachedResult := "Email sent (CACHED)"

	// 1. Pre-fill the registry with the auto-generated ID
	if err := registry.Store(sessionKey, autoExecID, cachedResult); err != nil {
		t.Fatalf("Store failed: %v", err)
	}

	// 2. Create the tool
	// We use dummy paths; Execute will still fail on auth IF it doesn't hit the cache.
	tool := newSendEmailTool(t.TempDir(), t.TempDir(), recipient, registry, nil, nil)

	// 3. Execute with NO execution_id in args
	args := map[string]any{
		"subject": "Hello",
		"body":    "World",
	}

	// This SHOULD hit the cache if the fix is working.
	// If it doesn't hit the cache, it will proceed to google.NewService and fail with auth error.
	resp, err := tool.Execute(context.Background(), sessionKey, "user-1", args)

	// BEFORE FIX: err will be "auth failure" or similar because it skipped the cache.
	// AFTER FIX: resp == cachedResult, err == nil.

	if err != nil {
		t.Errorf("Execute failed: %v (likely missed cache)", err)
	}
	if resp != cachedResult {
		t.Errorf("got resp %q, want %q", resp, cachedResult)
	}
}

func TestSendEmailTool_NonCronNoAutoIdempotency(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	registry := NewToolRegistry(tmpDir)

	sessionKey := "user_chat_123"
	recipient := "user@example.com"

	// Even if we have something in the registry for a similar auto-key
	date := time.Now().Format("2006-01-02")
	autoExecID := fmt.Sprintf("scheduled_email_auto_%s", date)
	cachedResult := "Should not hit"
	_ = registry.Store(sessionKey, autoExecID, cachedResult)

	tool := newSendEmailTool(t.TempDir(), t.TempDir(), recipient, registry, nil, nil)
	args := map[string]any{
		"subject": "Hello",
		"body":    "World",
	}

	// Should NOT hit cache, so should fail with auth error.
	_, err := tool.Execute(context.Background(), sessionKey, "user-1", args)
	if err == nil {
		t.Fatal("Expected auth failure for non-cron session without execution_id, but got success (cache hit?)")
	}
	if strings.Contains(err.Error(), "CACHED") {
		t.Error("Non-cron session hit the auto-generated idempotency key")
	}
}
