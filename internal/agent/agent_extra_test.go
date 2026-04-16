//nolint:testpackage // intentionally uses unexported internals for testing
package agent

import (
	"context"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
)

const testSess = "sess"

func TestSessionManager_Setters(t *testing.T) {
	t.Parallel()
	mgr := &SessionManager{}
	
	mgr.SetTracer(nil)
	mgr.SetLockTimeout(10 * time.Second)
	if mgr.lockTimeout != 10*time.Second {
		t.Errorf("SetLockTimeout failed")
	}
	
	p := config.ContextPruningConfig{TTL: "24h"}
	mgr.SetPruningPolicy(p)
	if mgr.pruningPolicy.TTL != "24h" {
		t.Errorf("SetPruningPolicy failed")
	}
	
	mgr.SetStorageRoot("/tmp")
	if mgr.storageRoot != "/tmp" {
		t.Errorf("SetStorageRoot failed")
	}
	
	mgr.SetLogger(nil)
	mgr.SetTokenBudget(1000)
	if mgr.tokenBudget != 1000 {
		t.Errorf("SetTokenBudget failed")
	}
	
	mgr.SetSummaryTurns(5)
	if mgr.summaryTurns != 5 {
		t.Errorf("SetSummaryTurns failed")
	}
}

func TestSessionManager_Compaction(t *testing.T) {
	t.Parallel()
	mgr := &SessionManager{
		summaryTurns: 2,
		runner:       &mockRunner{response: "summary result"},
	}
	
	messages := []agentctx.StrategicMessage{
		{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: testStrPtr("m1")}},
		{Role: agentctx.RoleAssistant, Content: &agentctx.MessageContent{Str: testStrPtr("r1")}},
		{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: testStrPtr("m2")}},
	}
	
	// buildCompactionSummary
	summary, err := mgr.buildCompactionSummary(context.Background(), testSess, messages)
	if err != nil {
		t.Fatal(err)
	}
	if summary != "summary result" {
		t.Errorf("got %q, want 'summary result'", summary)
	}
	
	// Error case
	mgr.runner = &mockRunner{err: context.DeadlineExceeded}
	_, err = mgr.buildCompactionSummary(context.Background(), testSess, messages)
	if err == nil {
		t.Error("expected error from runner")
	}
}

func TestSessionManager_EstimateTokens(t *testing.T) {
	t.Parallel()
	
	msg := "hello world"
	messages := []agentctx.StrategicMessage{
		{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: &msg}},
	}
	
	tokens := estimateTokensForMessages(messages)
	if tokens <= 0 {
		t.Errorf("expected positive token estimate, got %d", tokens)
	}
}

func TestSessionManager_CompactHistoryIfNeeded(t *testing.T) {
	t.Parallel()
	mgr := &SessionManager{
		memoryWindow: 2,
	}
	
	messages := []agentctx.StrategicMessage{
		{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: testStrPtr("m1")}},
		{Role: agentctx.RoleAssistant, Content: &agentctx.MessageContent{Str: testStrPtr("r1")}},
		{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: testStrPtr("m2")}},
		{Role: agentctx.RoleAssistant, Content: &agentctx.MessageContent{Str: testStrPtr("r2")}},
	}
	
	got := mgr.compactHistoryIfNeeded("sess", messages)
	if len(got) >= len(messages) {
		t.Errorf("expected compaction, got %d messages", len(got))
	}
}

func TestSessionManager_AddMissingTimestamps(t *testing.T) {
	t.Parallel()
	mgr := &SessionManager{}
	
	msg1 := agentctx.StrategicMessage{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: testStrPtr("m1")}}
	messages := []agentctx.StrategicMessage{msg1}
	
	mgr.addMissingTimestamps(messages)
	if messages[0].CreatedAt == "" {
		t.Error("addMissingTimestamps failed to set timestamp")
	}
}

func TestSessionManager_UpdateTokenBudget(t *testing.T) {
	t.Parallel()
	mgr := &SessionManager{
		tokenBudget: 1000,
	}
	
	msg1 := agentctx.StrategicMessage{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: testStrPtr("hello world")}}
	messages := []agentctx.StrategicMessage{msg1}
	
	mgr.updateTokenBudget(context.Background(), "sess", messages, nil)
	// Just verify it doesn't panic and calls estimateTokensForMessages
}

func testStrPtr(s string) *string { return &s }
