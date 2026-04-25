//nolint:testpackage // requires unexported mock types for testing
package agent

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
)

func TestSessionManager_Dispatch_Summarization(t *testing.T) {
	t.Parallel()
	expectedSummary := "<context_summary>\n* Key decision: Use Go\n</context_summary>"
	mock := &mockRunner{response: expectedSummary}
	store := newMockStore()
	sm := NewSessionManager(mock, store, "gemini-test")
	sm.memoryWindow = 10
	sm.compactionPolicy = config.CompactionPolicyConfig{
		Summarization: config.SummarizationConfig{
			Enabled:   true,
			Threshold: 0.5, // Trigger at 5 messages
		},
	}

	messages := make([]agentctx.StrategicMessage, 8)
	for i := range 8 {
		content := fmt.Sprintf("message %d", i)
		role := agentctx.RoleUser
		if i%2 == 1 {
			role = agentctx.RoleAssistant
		}
		messages[i] = agentctx.StrategicMessage{
			Role:    role,
			Content: &agentctx.MessageContent{Str: &content},
		}
	}
	_, _ = store.SaveSnapshot(context.Background(), "test-session", 1, messages)

	ctx := context.Background()
	_, err := sm.Dispatch(ctx, "test-session", "", "new message")
	if err != nil {
		t.Fatalf("dispatch failed: %v", err)
	}

	if len(mock.calls) == 0 {
		t.Fatal("mock runner was not called")
	}

	lastCall := mock.calls[len(mock.calls)-1]
	if len(lastCall.messages) == 0 {
		t.Fatal("last call history is empty")
	}

	firstMsg := lastCall.messages[0]
	if firstMsg.Role != agentctx.RoleSystem {
		t.Errorf("expected first message role 'system', got %q", firstMsg.Role)
	}
	if firstMsg.Content.String() != expectedSummary {
		t.Errorf("expected summary content %q, got %q", expectedSummary, firstMsg.Content.String())
	}

	if len(lastCall.messages) != 7 {
		t.Errorf("expected history length 7, got %d", len(lastCall.messages))
	}
}

func TestSessionManager_Dispatch_HierarchicalSummarization(t *testing.T) {
	t.Parallel()
	initialSummary := "<context_summary>\n* Old decision: Use Go\n</context_summary>"
	newSummary := "<context_summary>\n* Old decision: Use Go\n* New decision: Use SQLite\n</context_summary>"

	mock := &mockRunner{response: newSummary}
	store := newMockStore()
	sm := NewSessionManager(mock, store, "gemini-test")
	sm.memoryWindow = 10
	sm.compactionPolicy = config.CompactionPolicyConfig{
		Summarization: config.SummarizationConfig{
			Enabled:   true,
			Threshold: 0.5,
		},
	}

	messages := make([]agentctx.StrategicMessage, 0, 8) // 1 system + 7 loop iterations
	messages = append(messages, agentctx.StrategicMessage{
		Role:    agentctx.RoleSystem,
		Content: &agentctx.MessageContent{Str: &initialSummary},
	})
	for i := range 7 {
		content := fmt.Sprintf("message %d", i)
		messages = append(messages, agentctx.StrategicMessage{
			Role:    agentctx.RoleUser,
			Content: &agentctx.MessageContent{Str: &content},
		})
	}
	_, _ = store.SaveSnapshot(context.Background(), "test-session", 1, messages)

	ctx := context.Background()
	_, err := sm.Dispatch(ctx, "test-session", "", "new message")
	if err != nil {
		t.Fatalf("dispatch failed: %v", err)
	}

	lastCall := mock.calls[len(mock.calls)-1]
	firstMsg := lastCall.messages[0]

	if firstMsg.Role != agentctx.RoleSystem {
		t.Errorf("expected first message role 'system', got %q", firstMsg.Role)
	}
	if firstMsg.Content.String() != newSummary {
		t.Errorf("expected hierarchical summary content %q, got %q", newSummary, firstMsg.Content.String())
	}
}

func TestSessionManager_Summarization_CappedInput(t *testing.T) {
	t.Parallel()
	mock := &mockRunner{response: "summary"}
	store := newMockStore()
	sm := NewSessionManager(mock, store, "gemini-test")
	sm.memoryWindow = 10
	sm.compactionPolicy = config.CompactionPolicyConfig{
		Summarization: config.SummarizationConfig{
			Enabled:   true,
			Threshold: 0.1,
		},
	}

	largeContent := strings.Repeat("A", 100*1024)
	messages := make([]agentctx.StrategicMessage, 10)
	for i := range 10 {
		messages[i] = agentctx.StrategicMessage{
			Role:    agentctx.RoleUser,
			Content: &agentctx.MessageContent{Str: &largeContent},
		}
	}
	_, _ = store.SaveSnapshot(context.Background(), "test-session", 1, messages)

	ctx := context.Background()
	_, err := sm.Dispatch(ctx, "test-session", "", "new message")
	if err != nil {
		t.Fatalf("dispatch failed: %v", err)
	}

	if len(mock.textCalls) == 0 {
		t.Fatal("mock runner.RunText was not called")
	}

	prompt := mock.textCalls[0]
	if len(prompt) > DefaultMaxCompactionInputBytes+2048 {
		t.Errorf("prompt length %d exceeds cap %d", len(prompt), DefaultMaxCompactionInputBytes)
	}

	count := strings.Count(prompt, largeContent)
	if count >= 10 {
		t.Errorf("expected truncation, found all %d", count)
	}
	if count == 0 {
		t.Error("expected at least one message in prompt")
	}
}
