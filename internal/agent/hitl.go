package agent

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/allthingscode/gobot/internal/bot"
)

const (
	hitlApproved = "approved"
	hitlRejected = "rejected"
	hitlPending  = "pending"
	hitlSending  = "sending"
)

// HITLStore abstracts the persistence layer for HITL approvals.
type HITLStore interface {
	GetHITLApproval(ctx context.Context, reqID string) (string, error)
	SaveHITLApproval(ctx context.Context, reqID, sessionKey, toolName string, args map[string]any, status string) error
}

// HITLManager manages human-in-the-loop approvals via Telegram.
type HITLManager struct {
	api             bot.API
	store           HITLStore
	highRiskTools   map[string]bool
	pending         map[string]chan bool
	mu              sync.Mutex
	approvalTimeout time.Duration
}

// NewHITLManager creates a HITLManager for the given API and set of high-risk tools.
func NewHITLManager(api bot.API, store HITLStore, tools []string) *HITLManager {
	hrt := make(map[string]bool, len(tools))
	for _, t := range tools {
		hrt[t] = true
	}
	return &HITLManager{
		api:             api,
		store:           store,
		highRiskTools:   hrt,
		pending:         make(map[string]chan bool),
		approvalTimeout: 10 * time.Minute,
	}
}

// PreToolHook is the hook function to be registered with agent.Hooks.
func (m *HITLManager) PreToolHook(ctx context.Context, sessionKey, toolName string, args map[string]any) (string, error) {
	if !m.highRiskTools[toolName] {
		return "", nil
	}

	// F-048: Auto-approve cron jobs (scheduled tasks)
	if bot.IsCronSession(sessionKey) {
		return "", nil
	}

	approved, err := m.RequestApproval(ctx, sessionKey, toolName, args)
	if err != nil {
		return "", err
	}
	if !approved {
		return "", fmt.Errorf("%w: permission denied by user", ErrToolDenied)
	}
	return "", nil
}

// RequestApproval sends an approval request to Telegram and waits for a response.
func (m *HITLManager) RequestApproval(ctx context.Context, sessionKey, toolName string, args map[string]any) (bool, error) {
	// F-048: Auto-approve cron jobs (scheduled tasks)
	if bot.IsCronSession(sessionKey) {
		return true, nil
	}

	chatID, err := m.parseTelegramChatID(sessionKey, toolName)
	if err != nil {
		return false, err
	}

	reqID := m.createRequestID(sessionKey, toolName, args)

	ch, err := m.registerWaiter(reqID)
	if err != nil {
		return false, err
	}
	defer m.releaseWaiter(reqID, ch)
	status, err := m.persistedStatus(ctx, reqID)
	if err != nil {
		return false, err
	}
	switch status {
	case hitlApproved, hitlRejected:
		return status == hitlApproved, nil
	case hitlPending:
		return m.waitForApproval(ctx, reqID, ch)
	}

	approvalText := renderHITLApproval(toolName, args)

	m.persistLifecycle(ctx, reqID, sessionKey, toolName, args, hitlSending)

	msg := bot.OutboundMessage{
		ChatID: chatID,
		Text:   approvalText,
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

	m.persistLifecycle(ctx, reqID, sessionKey, toolName, args, hitlPending)
	return m.waitForApproval(ctx, reqID, ch)
}

// renderHITLApproval protects dynamic JSON from the adapter's fixed code fences.
func renderHITLApproval(toolName string, args map[string]any) string {
	toolJSON, _ := json.Marshal(toolName)
	argsJSON, _ := json.MarshalIndent(args, "", "  ")
	protect := func(value []byte) string {
		return strings.ReplaceAll(string(value), "`", `\u0060`)
	}
	return fmt.Sprintf("**Approval Required**\nTool:\n```\n%s\n```\nArgs:\n```\n%s\n```", protect(toolJSON), protect(argsJSON))
}

func (m *HITLManager) persistedStatus(ctx context.Context, reqID string) (string, error) {
	if m.store == nil {
		return "", nil
	}
	status, err := m.store.GetHITLApproval(ctx, reqID)
	if err != nil {
		return "", fmt.Errorf("HITL: read approval status: %w", err)
	}
	return status, nil
}

func (m *HITLManager) persistLifecycle(ctx context.Context, reqID, sessionKey, toolName string, args map[string]any, status string) {
	if m.store != nil {
		if err := m.store.SaveHITLApproval(ctx, reqID, sessionKey, toolName, args, status); err != nil {
			slog.Warn("HITL: failed to persist delivery status", "reqID", reqID, "status", status, "err", err)
		}
	}
}

func (m *HITLManager) registerWaiter(reqID string) (chan bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, exists := m.pending[reqID]; exists {
		return nil, fmt.Errorf("HITL: request %s already pending", reqID)
	}
	ch := make(chan bool, 1)
	m.pending[reqID] = ch
	return ch, nil
}

func (m *HITLManager) releaseWaiter(reqID string, ch chan bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.pending[reqID] == ch {
		delete(m.pending, reqID)
	}
}

func (m *HITLManager) parseTelegramChatID(sessionKey, toolName string) (int64, error) {
	// Parse chatID from sessionKey (format: "telegram:chatID" or "telegram:chatID:threadID")
	if !bot.IsTelegramSession(sessionKey) {
		parts := strings.Split(sessionKey, ":")
		channel := "unknown"
		if len(parts) > 0 && parts[0] != "" {
			channel = parts[0]
		}
		// B-056: Fail closed for non-Telegram sessions.
		return 0, fmt.Errorf("HITL: high-risk tool %q requires human approval, but session channel %q is unsupported for HITL", toolName, channel)
	}
	parts := strings.Split(sessionKey, ":")
	chatID, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil {
		return 0, fmt.Errorf("HITL: failed to parse chat ID from session key %q: %w", sessionKey, err)
	}
	return chatID, nil
}

func (m *HITLManager) waitForApproval(ctx context.Context, reqID string, ch chan bool) (bool, error) {
	// Live callbacks decide the request even when their best-effort write fails.
	select {
	case approved := <-ch:
		return approved, nil
	default:
	}
	status, err := m.persistedStatus(ctx, reqID)
	if err != nil {
		return false, err
	}
	if status == hitlApproved || status == hitlRejected {
		return status == hitlApproved, nil
	}
	timer := time.NewTimer(m.approvalTimeout)
	defer timer.Stop()

	select {
	case <-ctx.Done():
		return false, fmt.Errorf("context done: %w", ctx.Err())
	case approved := <-ch:
		return approved, nil
	case <-timer.C: // Timeout for human response
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
	approved := action == "approve"

	status := hitlApproved
	if !approved {
		status = hitlRejected
	}

	// Persist the decision
	if m.store != nil {
		if err := m.store.SaveHITLApproval(ctx, reqID, "", "", nil, status); err != nil {
			slog.Warn("HITL: failed to persist decision", "reqID", reqID, "status", status, "err", err)
		}
	}

	m.mu.Lock()
	ch, ok := m.pending[reqID]
	m.mu.Unlock()

	if !ok {
		// Possibly expired, already handled, or bot restarted
		slog.Info("HITL: callback received for non-pending request (persisted)", "reqID", reqID, "action", action)
		msgStatus := "Approved"
		if !approved {
			msgStatus = "Rejected"
		}
		_ = m.api.Send(ctx, bot.OutboundMessage{
			ChatID: cb.ChatID,
			Text:   fmt.Sprintf("Request %s (persisted).", msgStatus),
		})
		return nil
	}

	slog.Info("HITL: callback received", "reqID", reqID, "action", action, "chatID", cb.ChatID)
	notifyHITLWaiter(ch, approved)

	displayStatus := "Approved"
	if !approved {
		displayStatus = "Rejected"
	}

	_ = m.api.Send(ctx, bot.OutboundMessage{
		ChatID: cb.ChatID,
		Text:   fmt.Sprintf("Request %s.", displayStatus),
	})

	return nil
}

// notifyHITLWaiter never blocks a duplicate callback or closes a racing channel.
func notifyHITLWaiter(ch chan bool, approved bool) {
	select {
	case ch <- approved:
	default:
	}
}

func (m *HITLManager) createRequestID(sessionKey, toolName string, args map[string]any) string {
	h := sha256.New()
	h.Write([]byte(sessionKey))
	h.Write([]byte(toolName))
	argBytes, _ := json.Marshal(args)
	h.Write(argBytes)
	return fmt.Sprintf("%x", h.Sum(nil))[:12]
}
