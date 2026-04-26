//nolint:testpackage // requires unexported mock types for testing
package agent

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/bot"
	"github.com/stretchr/testify/assert"
)

const (
	statusApprovedVal = "approved"
	statusRejectedVal = "rejected"
	statusPendingVal  = "pending"
)

type mockBotAPI struct {
	bot.API
	mu           sync.Mutex
	sentMessages []bot.OutboundMessage
	sentButtons  [][][]bot.Button
}

func (m *mockBotAPI) Send(ctx context.Context, msg bot.OutboundMessage) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.sentMessages = append(m.sentMessages, msg)
	return nil
}

func (m *mockBotAPI) SendWithButtons(ctx context.Context, msg bot.OutboundMessage, buttons [][]bot.Button) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.sentMessages = append(m.sentMessages, msg)
	m.sentButtons = append(m.sentButtons, buttons)
	return nil
}

func (m *mockBotAPI) getSentButtons() [][][]bot.Button {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.sentButtons
}

func TestHITLManager_PreToolHook_NonHighRisk(t *testing.T) {
	t.Parallel()
	api := &mockBotAPI{}
	m := NewHITLManager(api, nil, []string{"high_risk"})

	got, err := m.PreToolHook(context.Background(), "telegram:123", "low_risk", nil)
	if err != nil {
		t.Fatalf("PreToolHook failed: %v", err)
	}
	if got != "" {
		t.Errorf("got %q, want empty string", got)
	}
	if len(api.sentMessages) > 0 {
		t.Error("sent messages for non-high-risk tool")
	}
}

func TestHITLManager_PreToolHook_Approve(t *testing.T) {
	t.Parallel()
	api := &mockBotAPI{}
	m := NewHITLManager(api, nil, []string{"high_risk"})

	ctx, cancel := context.WithTimeout(context.Background(), 1*time.Second)
	defer cancel()

	// Use a channel to synchronize the callback
	done := make(chan struct{})
	var got string
	var err error

	go func() {
		got, err = m.PreToolHook(ctx, "telegram:123", "high_risk", nil)
		close(done)
	}()

	// Wait for the message to be sent
	assert.Eventually(t, func() bool {
		m.mu.Lock()
		defer m.mu.Unlock()
		return len(m.pending) > 0
	}, 1*time.Second, 10*time.Millisecond)

	// Extract reqID from sent buttons
	sentButtons := api.getSentButtons()
	if len(sentButtons) == 0 {
		t.Fatal("no buttons sent")
	}
	data := sentButtons[0][0][0].Data // hitl:approve:reqID

	// Simulate approval callback
	cb := bot.InboundCallback{
		ChatID: 123,
		Data:   data,
	}
	if cbErr := m.HandleCallback(ctx, cb); cbErr != nil {
		t.Fatalf("HandleCallback failed: %v", cbErr)
	}

	<-done

	if err != nil {
		t.Fatalf("PreToolHook failed: %v", err)
	}
	if got != "" {
		t.Errorf("got %q, want empty string", got)
	}
}

func TestHITLManager_PreToolHook_Reject(t *testing.T) {
	t.Parallel()
	api := &mockBotAPI{}
	m := NewHITLManager(api, nil, []string{"high_risk"})

	ctx, cancel := context.WithTimeout(context.Background(), 1*time.Second)
	defer cancel()

	// Use a channel to synchronize the callback
	done := make(chan struct{})
	var got string
	var err error

	go func() {
		got, err = m.PreToolHook(ctx, "telegram:123", "high_risk", nil)
		close(done)
	}()

	// Wait for the message to be sent
	assert.Eventually(t, func() bool {
		m.mu.Lock()
		defer m.mu.Unlock()
		return len(m.pending) > 0
	}, 1*time.Second, 10*time.Millisecond)

	// Extract reqID from sent buttons
	sentButtons := api.getSentButtons()
	if len(sentButtons) == 0 {
		t.Fatal("no buttons sent")
	}
	data := sentButtons[0][0][1].Data // hitl:reject:reqID

	// Simulate rejection callback
	cb := bot.InboundCallback{
		ChatID: 123,
		Data:   data,
	}
	if cbErr := m.HandleCallback(ctx, cb); cbErr != nil {
		t.Fatalf("HandleCallback failed: %v", cbErr)
	}

	<-done

	if err == nil {
		t.Fatal("PreToolHook expected error (rejected), got nil")
	}
	if !errors.Is(err, ErrToolDenied) {
		t.Errorf("expected ErrToolDenied, got %v", err)
	}
	if got != "" {
		t.Errorf("got %q, want empty string (rejected)", got)
	}
}

func TestHITLManager_PreToolHook_FailClosed(t *testing.T) {
	t.Parallel()
	api := &mockBotAPI{}
	m := NewHITLManager(api, nil, []string{"high_risk"})

	tests := []struct {
		name       string
		sessionKey string
		toolName   string
		wantErr    string
	}{
		{
			name:       "Non-Telegram session",
			sessionKey: "cli:user123",
			toolName:   "high_risk",
			wantErr:    "unsupported for HITL",
		},
		{
			name:       "Invalid chat ID",
			sessionKey: "telegram:abc",
			toolName:   "high_risk",
			wantErr:    "failed to parse chat ID",
		},
		{
			name:       "Missing chat ID",
			sessionKey: "telegram",
			toolName:   "high_risk",
			wantErr:    "unsupported for HITL",
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			_, err := m.PreToolHook(context.Background(), tt.sessionKey, tt.toolName, nil)
			if err == nil {
				t.Error("expected error, got nil")
			} else if !strings.Contains(err.Error(), tt.wantErr) {
				t.Errorf("expected error containing %q, got %v", tt.wantErr, err)
			}
		})
	}
}

type mockHITLStore struct {
	approvals map[string]string
	mu        sync.Mutex
}

func (m *mockHITLStore) GetHITLApproval(ctx context.Context, reqID string) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.approvals[reqID], nil
}

func (m *mockHITLStore) SaveHITLApproval(ctx context.Context, reqID, _, _ string, _ map[string]any, status string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.approvals == nil {
		m.approvals = make(map[string]string)
	}
	m.approvals[reqID] = status
	return nil
}

func TestHITLManager_Persistence(t *testing.T) {
	t.Parallel()
	api := &mockBotAPI{}
	store := &mockHITLStore{approvals: make(map[string]string)}
	m := NewHITLManager(api, store, []string{"high_risk"})

	sessionKey := "telegram:123"
	toolName := "high_risk"
	args := map[string]any{"cmd": "ls"}
	reqID := m.createRequestID(sessionKey, toolName, args)

	// 1. Simulate a previous approval in the store
	store.approvals[reqID] = statusApprovedVal

	got, err := m.PreToolHook(context.Background(), sessionKey, toolName, args)
	if err != nil {
		t.Fatalf("PreToolHook failed: %v", err)
	}
	if got != "" {
		t.Errorf("expected auto-approval from store, got %q", got)
	}
	if len(api.sentMessages) > 0 {
		t.Errorf("sent %d messages, expected 0 (already approved)", len(api.sentMessages))
	}

	// 2. Simulate a previous rejection
	reqID2 := m.createRequestID(sessionKey, toolName, map[string]any{"cmd": "rm"})
	store.approvals[reqID2] = statusRejectedVal

	_, err = m.PreToolHook(context.Background(), sessionKey, toolName, map[string]any{"cmd": "rm"})
	if !errors.Is(err, ErrToolDenied) {
		t.Errorf("expected ErrToolDenied, got %v", err)
	}

	// 3. Simulate pending status (resuming)
	reqID3 := m.createRequestID(sessionKey, toolName, map[string]any{"cmd": "mv"})
	store.approvals[reqID3] = statusPendingVal

	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()

	done := make(chan struct{})
	go func() {
		_, _ = m.PreToolHook(ctx, sessionKey, toolName, map[string]any{"cmd": "mv"})
		close(done)
	}()

	// Should be waiting on channel, not sending message.
	// Wait until it reaches the blocking point.
	assert.Eventually(t, func() bool {
		m.mu.Lock()
		defer m.mu.Unlock()
		return len(m.pending) > 0
	}, 1*time.Second, 10*time.Millisecond)

	if len(api.sentMessages) > 0 {
		t.Errorf("sent messages for pending request, expected 0")
	}

	// Simulate approval via callback
	if err := m.HandleCallback(context.Background(), bot.InboundCallback{
		ChatID: 123,
		Data:   "hitl:approve:" + reqID3,
	}); err != nil {
		t.Fatalf("HandleCallback failed: %v", err)
	}

	<-done
	if store.approvals[reqID3] != statusApprovedVal {
		t.Errorf("expected store to be updated to approved, got %q", store.approvals[reqID3])
	}
}
