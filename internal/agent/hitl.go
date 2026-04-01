package agent

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/allthingscode/gobot/internal/bot"
)

// HITLManager manages human-in-the-loop approvals via Telegram.
type HITLManager struct {
	api           bot.API
	highRiskTools map[string]bool
	pending       map[string]chan bool
	mu            sync.Mutex
}

// NewHITLManager creates a HITLManager for the given API and set of high-risk tools.
func NewHITLManager(api bot.API, tools []string) *HITLManager {
	hrt := make(map[string]bool, len(tools))
	for _, t := range tools {
		hrt[t] = true
	}
	return &HITLManager{
		api:           api,
		highRiskTools: hrt,
		pending:       make(map[string]chan bool),
	}
}

// PreToolHook is the hook function to be registered with agent.Hooks.
func (m *HITLManager) PreToolHook(ctx context.Context, sessionKey string, toolName string, args map[string]any) (string, error) {
	if !m.highRiskTools[toolName] {
		return "", nil
	}

	// F-048: Auto-approve cron jobs (scheduled tasks)
	if strings.HasPrefix(sessionKey, "cron:") {
		return "", nil
	}

	approved, err := m.RequestApproval(ctx, sessionKey, toolName, args)
	if err != nil {
		return "", err
	}
	if !approved {
		return "Permission denied by user.", nil
	}
	return "", nil
}

// RequestApproval sends an approval request to Telegram and waits for a response.
func (m *HITLManager) RequestApproval(ctx context.Context, sessionKey string, toolName string, args map[string]any) (bool, error) {
	// Parse chatID from sessionKey (format: "telegram:chatID" or "telegram:chatID:threadID")
	parts := strings.Split(sessionKey, ":")
	if len(parts) < 2 || parts[0] != "telegram" {
		// Not a Telegram session; skip HITL for now (or fail closed if preferred)
		return true, nil
	}
	chatID, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil {
		return true, nil
	}

	argBytes, _ := json.MarshalIndent(args, "", "  ")
	reqID := m.createRequestID(sessionKey, toolName, args)
	
	m.mu.Lock()
	ch := make(chan bool, 1)
	m.pending[reqID] = ch
	m.mu.Unlock()

	defer func() {
		m.mu.Lock()
		delete(m.pending, reqID)
		m.mu.Unlock()
	}()

	msg := bot.OutboundMessage{
		ChatID: chatID,
		Text:   fmt.Sprintf("<b>Approval Required</b>\nTool: <code>%s</code>\nArgs:\n<pre>%s</pre>", toolName, string(argBytes)),
	}
	buttons := [][]bot.Button{
		{
			{Text: "✅ Approve", Data: "hitl:approve:" + reqID},
			{Text: "❌ Reject", Data: "hitl:reject:" + reqID},
		},
	}

	if err := m.api.SendWithButtons(ctx, msg, buttons); err != nil {
		return false, fmt.Errorf("HITL: failed to send request: %w", err)
	}

	select {
	case <-ctx.Done():
		return false, ctx.Err()
	case approved := <-ch:
		return approved, nil
	case <-time.After(10 * time.Minute): // Timeout for human response
		return false, fmt.Errorf("HITL: approval timeout")
	}
}

// HandleCallback processes HITL callback queries.
func (m *HITLManager) HandleCallback(ctx context.Context, cb bot.InboundCallback) error {
	if !strings.HasPrefix(cb.Data, "hitl:") {
		return nil
	}

	parts := strings.Split(cb.Data, ":")
	if len(parts) < 3 {
		return nil
	}

	action := parts[1]
	reqID := parts[2]

	m.mu.Lock()
	ch, ok := m.pending[reqID]
	m.mu.Unlock()

	if !ok {
		// Possibly expired or already handled
		_ = m.api.Send(ctx, bot.OutboundMessage{
			ChatID: cb.ChatID,
			Text:   "This request has expired or already been handled.",
		})
		return nil
	}

	approved := action == "approve"
	ch <- approved

	status := "Approved"
	if !approved {
		status = "Rejected"
	}

	_ = m.api.Send(ctx, bot.OutboundMessage{
		ChatID: cb.ChatID,
		Text:   fmt.Sprintf("Request %s.", status),
	})

	return nil
}

func (m *HITLManager) createRequestID(sessionKey, toolName string, args map[string]any) string {
	h := sha256.New()
	h.Write([]byte(sessionKey))
	h.Write([]byte(toolName))
	argBytes, _ := json.Marshal(args)
	h.Write(argBytes)
	return fmt.Sprintf("%x", h.Sum(nil))[:12]
}
