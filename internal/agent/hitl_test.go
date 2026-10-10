//nolint:testpackage // requires unexported mock types for testing
package agent

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/telegram"
	"github.com/stretchr/testify/assert"
)

type mockBotAPI struct {
	bot.API
	mu           sync.Mutex
	sentMessages []bot.OutboundMessage
	sentButtons  [][][]bot.Button
}

func TestHITLChannelTimeout(t *testing.T) {
	t.Parallel()
	api := &mockBotAPI{}
	m := NewHITLManager(api, nil, nil)
	m.ConfigureChannelApproval(true, func(string) bool { return true })
	m.approvalTimeout = time.Millisecond
	_, err := m.PreToolHook(context.Background(), "telegram:123:456", "custom_write", nil)
	if err == nil || !strings.Contains(err.Error(), "approval timeout") {
		t.Fatalf("expected approval timeout, got %v", err)
	}
	if len(api.getSentButtons()) != 1 || len(m.pending) != 0 {
		t.Fatal("timeout must send one request and release the waiter")
	}
}

func TestHITLUnavailableAPI(t *testing.T) {
	t.Parallel()
	for _, source := range []string{"channel", "high risk", "policy"} {
		t.Run(source, func(t *testing.T) {
			t.Parallel()
			m := NewHITLManager(nil, nil, []string{"risky"})
			m.ConfigureChannelApproval(true, func(string) bool { return true })
			var err error
			switch source {
			case "channel":
				_, err = m.PreToolHook(context.Background(), "telegram:123", "write", nil)
			case "high risk":
				_, err = m.PreToolHook(context.Background(), "telegram:123", "risky", nil)
			case "policy":
				_, err = m.RequestApproval(context.Background(), "telegram:123", "read", nil)
			}
			if err == nil || !strings.Contains(err.Error(), "available Telegram API") {
				t.Fatalf("approval must fail closed without API, got %v", err)
			}
		})
	}
}

func TestHITLChannelWithoutPredicate(t *testing.T) {
	t.Parallel()
	m := NewHITLManager(nil, nil, nil)
	m.ConfigureChannelApproval(true, nil)
	if _, err := m.PreToolHook(context.Background(), "telegram:123", "read", nil); err != nil {
		t.Fatal(err)
	}
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
		return len(m.pending) > 0 && len(api.getSentButtons()) > 0
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
		return len(m.pending) > 0 && len(api.getSentButtons()) > 0
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
	if (status == "sending" || status == hitlPending) && (m.approvals[reqID] == hitlApproved || m.approvals[reqID] == hitlRejected) {
		return nil
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
	store.approvals[reqID] = hitlApproved

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
	store.approvals[reqID2] = hitlRejected

	_, err = m.PreToolHook(context.Background(), sessionKey, toolName, map[string]any{"cmd": "rm"})
	if !errors.Is(err, ErrToolDenied) {
		t.Errorf("expected ErrToolDenied, got %v", err)
	}

	// 3. Simulate pending status (resuming)
	reqID3 := m.createRequestID(sessionKey, toolName, map[string]any{"cmd": "mv"})
	store.approvals[reqID3] = hitlPending

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
	if store.approvals[reqID3] != hitlApproved {
		t.Errorf("expected store to be updated to approved, got %q", store.approvals[reqID3])
	}
}

func assertHITLHTML(t *testing.T, markdown, tool string, args map[string]any) {
	t.Helper()
	toolJSON, err := json.Marshal(tool)
	if err != nil {
		t.Fatal(err)
	}
	argsJSON, err := json.MarshalIndent(args, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	payloads := []string{strings.ReplaceAll(string(toolJSON), "`", `\u0060`), strings.ReplaceAll(string(argsJSON), "`", `\u0060`)}
	expected := "<b>Approval Required</b>\nTool:\n<pre><code>" + html.EscapeString(payloads[0]) + "\n</code></pre>\nArgs:\n<pre><code>" + html.EscapeString(payloads[1]) + "\n</code></pre>"
	actual := telegram.ToHTML(markdown)
	if actual != expected {
		t.Fatalf("HTML mismatch\ngot: %s\nwant: %s", actual, expected)
	}
	var decodedTool string
	var decodedArgs, normalizedArgs map[string]any
	blocks := strings.Split(actual, "<pre><code>")
	if err := json.Unmarshal([]byte(html.UnescapeString(strings.Split(blocks[1], "</code></pre>")[0])), &decodedTool); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(html.UnescapeString(strings.Split(blocks[2], "</code></pre>")[0])), &decodedArgs); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(argsJSON, &normalizedArgs); err != nil {
		t.Fatal(err)
	}
	if decodedTool != tool || !reflect.DeepEqual(decodedArgs, normalizedArgs) {
		t.Fatalf("JSON round trip mismatch: %q, %#v", decodedTool, decodedArgs)
	}
}

func TestRenderHITLApproval(t *testing.T) {
	t.Parallel()
	type testCase struct {
		name, tool string
		args       map[string]any
	}
	cases := append(make([]testCase, 0, 13), []testCase{
		{"ordinary", "shell", map[string]any{"command": "pwd", "count": 2}},
		{"nil", "shell", nil},
		{"empty", "", map[string]any{}},
		{"nested", "工具🙂", map[string]any{"nested": map[string]any{"list": []any{true, nil, 1, "é🙂"}}}},
	}...)
	for _, hostile := range []string{"line one\nline two", "<b>x</b>&<script>", "**bold** _italic_ [link](https://example.com)", "\"quote\"\\path\nnext", "`", "``", "```", "``````", `\u0060`} {
		cases = append(cases, testCase{hostile, hostile, map[string]any{hostile: hostile}})
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			assertHITLHTML(t, renderHITLApproval(tc.tool, tc.args), tc.tool, tc.args)
		})
	}
}

type formattingHITLAPI struct {
	mockBotAPI
	onSend func(context.Context, bot.OutboundMessage, [][]bot.Button) error
}

func (a *formattingHITLAPI) SendWithButtons(ctx context.Context, msg bot.OutboundMessage, buttons [][]bot.Button) error {
	return a.onSend(ctx, msg, buttons)
}

type formattingHITLStore struct {
	mockHITLStore
	t                    *testing.T
	session, tool, reqID string
	args                 map[string]any
	statuses             []string
}

func (s *formattingHITLStore) SaveHITLApproval(ctx context.Context, reqID, session, tool string, args map[string]any, status string) error {
	s.t.Helper()
	if reqID != s.reqID {
		s.t.Fatalf("changed request ID: %s", reqID)
	}
	if status == hitlSending || status == hitlPending {
		if session != s.session || tool != s.tool || !reflect.DeepEqual(args, s.args) {
			s.t.Fatal("display encoding changed stored inputs")
		}
	}
	s.statuses = append(s.statuses, status)
	return s.mockHITLStore.SaveHITLApproval(ctx, reqID, session, tool, args, status)
}

func TestHITLRequestApprovalFormatting(t *testing.T) {
	t.Parallel()
	const session = "telegram:123:456"
	const tool = "<b>**tool**```\\u0060"
	args := map[string]any{"```<key>": "[value](url)&```\\u0060"}
	argJSON, err := json.Marshal(args)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(append([]byte(session+tool), argJSON...))
	reqID := fmt.Sprintf("%x", sum)[:12]
	store := &formattingHITLStore{t: t, session: session, tool: tool, args: args, reqID: reqID}
	api := &formattingHITLAPI{}
	manager := NewHITLManager(api, store, []string{tool})
	sent := false
	api.onSend = func(ctx context.Context, msg bot.OutboundMessage, buttons [][]bot.Button) error {
		sent = true
		if msg.ChatID != 123 {
			t.Fatalf("wrong chat: %d", msg.ChatID)
		}
		assertHITLHTML(t, msg.Text, tool, args)
		expected := [][]bot.Button{{{Text: "✅ Approve", Data: "hitl:approve:" + reqID}, {Text: "❌ Reject", Data: "hitl:reject:" + reqID}}}
		if !reflect.DeepEqual(buttons, expected) {
			t.Fatalf("buttons changed: %#v", buttons)
		}
		return manager.HandleCallback(ctx, bot.InboundCallback{ChatID: 123, Data: buttons[0][0].Data})
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	approved, err := manager.RequestApproval(ctx, session, tool, args)
	if err != nil || !approved || !sent {
		t.Fatalf("request: approved=%v sent=%v err=%v", approved, sent, err)
	}
	if !reflect.DeepEqual(store.statuses, []string{hitlSending, hitlApproved, hitlPending}) {
		t.Fatalf("lifecycle changed: %v", store.statuses)
	}
}
