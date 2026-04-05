package agent

import (
	"context"
	"fmt"
	"testing"

	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
)

func TestSessionManager_Dispatch_Summarization(t *testing.T) {
	// Setup SessionManager with summarization enabled.
	expectedSummary := "<context_summary>\n* Key decision: Use Go\n</context_summary>"
	mock := &mockRunner{response: expectedSummary}
	sm := NewSessionManager(mock, nil, "gemini-test")
	sm.memoryWindow = 10
	sm.compactionPolicy = config.CompactionPolicyConfig{
		Summarization: config.SummarizationConfig{
			Enabled:          true,
			ThresholdPercent: 0.5, // Trigger at 5 messages
		},
	}

	// Create a history of 8 messages (exceeds threshold of 5).
	// keepN will be 10/2 = 5.
	// toSummarize will be 8 - 5 = 3 messages.
	messages := make([]agentctx.StrategicMessage, 8)
	for i := 0; i < 8; i++ {
		content := fmt.Sprintf("message %d", i)
		role := "user"
		if i%2 == 1 {
			role = "assistant"
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
	if firstMsg.Role != "system" {
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
	// Setup SessionManager with summarization enabled.
	initialSummary := "<context_summary>\n* Old decision: Use Go\n</context_summary>"
	newSummary := "<context_summary>\n* Old decision: Use Go\n* New decision: Use SQLite\n</context_summary>"
	
	mock := &mockRunner{response: newSummary}
	sm := NewSessionManager(mock, nil, "gemini-test")
	sm.memoryWindow = 10
	sm.compactionPolicy = config.CompactionPolicyConfig{
		Summarization: config.SummarizationConfig{
			Enabled:          true,
			ThresholdPercent: 0.5,
		},
	}

	// Create a history starting with an existing summary.
	messages := []agentctx.StrategicMessage{
		{
			Role:    "system",
			Content: &agentctx.MessageContent{Str: &initialSummary},
		},
	}
	// Add 7 more messages to trigger summarization again.
	for i := 0; i < 7; i++ {
		content := fmt.Sprintf("message %d", i)
		messages = append(messages, agentctx.StrategicMessage{
			Role:    "user",
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
	
	if firstMsg.Role != "system" {
		t.Errorf("expected first message role 'system', got %q", firstMsg.Role)
	}
	if firstMsg.Content.String() != newSummary {
		t.Errorf("expected hierarchical summary content %q, got %q", newSummary, firstMsg.Content.String())
	}
}
