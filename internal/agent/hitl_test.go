package agent

import (
	"context"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/bot"
)

type mockBotAPI struct {
	bot.API
	sentMessages []bot.OutboundMessage
	sentButtons  [][][]bot.Button
}

func (m *mockBotAPI) Send(ctx context.Context, msg bot.OutboundMessage) error {
	m.sentMessages = append(m.sentMessages, msg)
	return nil
}

func (m *mockBotAPI) SendWithButtons(ctx context.Context, msg bot.OutboundMessage, buttons [][]bot.Button) error {
	m.sentMessages = append(m.sentMessages, msg)
	m.sentButtons = append(m.sentButtons, buttons)
	return nil
}

func TestHITLManager_PreToolHook_NonHighRisk(t *testing.T) {
	api := &mockBotAPI{}
	m := NewHITLManager(api, []string{"high_risk"})

	got, err := m.PreToolHook(context.Background(), "telegram:123", "low_risk", nil)
	if err != nil {
		t.Fatalf("PreToolHook failed: %v", err)
	}
	if got != "" {
		t.Errorf("got %q, want empty string", got)
	}
}

func TestHITLManager_PreToolHook_Approve(t *testing.T) {
	api := &mockBotAPI{}
	m := NewHITLManager(api, []string{"high_risk"})

	ctx, cancel := context.WithTimeout(context.Background(), 1*time.Second)
	defer cancel()

	// Use a channel to synchronize the callback
	done := make(chan struct{})
	var got string
	var err error

	go func() {
		got, err = m.PreToolHook(ctx, "telegram:123", "high_risk", map[string]any{"cmd": "rm -rf /"})
		close(done)
	}()

	// Wait for the message to be sent
	for {
		m.mu.Lock()
		numPending := len(m.pending)
		m.mu.Unlock()
		if numPending > 0 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	// Extract reqID from sent buttons
	if len(api.sentButtons) == 0 {
		t.Fatal("no buttons sent")
	}
	data := api.sentButtons[0][0][0].Data // hitl:approve:reqID

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
		t.Errorf("got %q, want empty string (approved)", got)
	}
}

func TestHITLManager_PreToolHook_Reject(t *testing.T) {
	api := &mockBotAPI{}
	m := NewHITLManager(api, []string{"high_risk"})

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
	for {
		m.mu.Lock()
		numPending := len(m.pending)
		m.mu.Unlock()
		if numPending > 0 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	// Extract reqID from sent buttons
	data := api.sentButtons[0][0][1].Data // hitl:reject:reqID

	// Simulate rejection callback
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
	if got != "Permission denied by user." {
		t.Errorf("got %q, want %q", got, "Permission denied by user.")
	}
}
