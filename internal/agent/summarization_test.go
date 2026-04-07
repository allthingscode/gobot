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
	// Setup SessionManager with summarization enabled.
	expectedSummary := "<context_summary>\n* Key decision: Use Go\n</context_summary>"
	mock := &mockRunner{response: expectedSummary}
	sm := NewSessionManager(mock, nil, "gemini-test")
	sm.memoryWindow = 10
	sm.compactionPolicy = config.CompactionPolicyConfig{
		Summarization: config.SummarizationConfig{
			IsEnabled:        true,
			ThresholdPercent: 0.5, // Trigger at 5 messages
		},
	}

	// Create a history of 8 messages (exceeds threshold of 5).
	// keepN will be 10/2 = 5.
	// toSummarize will be 8 - 5 = 3 messages.
	messages := make([]agentctx.StrategicMessage, 8)
	for i := 0; i < 8; i++ {
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

	// Dispatch with this history.
	ctx := context.Background()
	_, err := sm.dispatch(ctx, "test-session", "new message", messages, 1, false)
	if err != nil {
		t.Fatalf("dispatch failed: %v", err)
	}

	// The last call in mock.calls should be the Runner.Run call.
	if len(mock.calls) == 0 {
		t.Fatal("mock runner was not called")
	}

	lastCall := mock.calls[len(mock.calls)-1]

	// The history should start with the summary message.
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

	// The total messages in history passed to Run should be:
	// 1 (summary) + 5 (retained) = 6.
	// Then dispatch appends the new user message, so 7.
	if len(lastCall.messages) != 7 {
		t.Errorf("expected history length 7, got %d", len(lastCall.messages))
	}
}

func TestSessionManager_Dispatch_HierarchicalSummarization(t *testing.T) {
	t.Parallel()
	// Setup SessionManager with summarization enabled.
	initialSummary := "<context_summary>\n* Old decision: Use Go\n</context_summary>"
	newSummary := "<context_summary>\n* Old decision: Use Go\n* New decision: Use SQLite\n</context_summary>"

	mock := &mockRunner{response: newSummary}
	sm := NewSessionManager(mock, nil, "gemini-test")
	sm.memoryWindow = 10
	sm.compactionPolicy = config.CompactionPolicyConfig{
		Summarization: config.SummarizationConfig{
			IsEnabled:        true,
			ThresholdPercent: 0.5,
		},
	}

	// Create a history starting with an existing summary.
	messages := []agentctx.StrategicMessage{
		{
			Role:    agentctx.RoleSystem,
			Content: &agentctx.MessageContent{Str: &initialSummary},
		},
	}
	// Add 7 more messages to trigger summarization again.
	for i := 0; i < 7; i++ {
		content := fmt.Sprintf("message %d", i)
		messages = append(messages, agentctx.StrategicMessage{
			Role:    agentctx.RoleUser,
			Content: &agentctx.MessageContent{Str: &content},
		})
	}

	// Dispatch.
	ctx := context.Background()
	_, err := sm.dispatch(ctx, "test-session", "new message", messages, 1, false)
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
	// Setup SessionManager with summarization enabled.
	mock := &mockRunner{response: "summary"}
	sm := NewSessionManager(mock, nil, "gemini-test")
	sm.memoryWindow = 10
	sm.compactionPolicy = config.CompactionPolicyConfig{
		Summarization: config.SummarizationConfig{
			IsEnabled:        true,
			ThresholdPercent: 0.1, // Trigger almost immediately
		},
	}

	// Create a history that will exceed DefaultMaxCompactionInputBytes.
	// DefaultMaxCompactionInputBytes = 512KB.
	// We'll create 10 messages, each 100KB.
	largeContent := strings.Repeat("A", 100*1024)
	messages := make([]agentctx.StrategicMessage, 10)
	for i := 0; i < 10; i++ {
		messages[i] = agentctx.StrategicMessage{
			Role:    agentctx.RoleUser,
			Content: &agentctx.MessageContent{Str: &largeContent},
		}
	}

	// Dispatch.
	ctx := context.Background()
	_, err := sm.dispatch(ctx, "test-session", "new message", messages, 1, false)
	if err != nil {
		t.Fatalf("dispatch failed: %v", err)
	}

	// Verify that RunText was called with a truncated prompt.
	// The prompt length should be roughly DefaultMaxCompactionInputBytes (+ prompt overhead),
	// but definitely much less than the 1MB+ of raw messages.
	if len(mock.textCalls) == 0 {
		t.Fatal("mock runner.RunText was not called")
	}

	prompt := mock.textCalls[0]
	if len(prompt) > DefaultMaxCompactionInputBytes+2048 { // Allow for some overhead (prompt prefix, role tags)
		t.Errorf("prompt length %d exceeds cap %d by too much overhead", len(prompt), DefaultMaxCompactionInputBytes)
	}

	// Verify that not all messages are in the prompt.
	// 10 messages * 100KB = 1MB.
	// Cap is 512KB. So at least 4-5 messages should be missing.
	// The strings.Count(prompt, largeContent) should be less than 10.
	count := strings.Count(prompt, largeContent)
	if count >= 10 {
		t.Errorf("expected some messages to be truncated, but found all %d", count)
	}
	if count == 0 {
		t.Error("expected at least one message in prompt, but found none")
	}
}
