package app

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/memory"
	"github.com/allthingscode/gobot/internal/memory/consolidator"
	"github.com/allthingscode/gobot/internal/resilience"
)

// DispatchHandler implements bot.Handler for the agentic dispatch loop.
// This is the core "gluing" component that connects the Telegram/Gateway bot
// to the agent session manager, long-term memory, and consolidation engine.
type DispatchHandler struct {
	Mgr          *agent.SessionManager
	Memory       *memory.MemoryStore        // may be nil
	Consolidator *consolidator.Consolidator // may be nil
	Hitl         *agent.HITLManager         // may be nil
}

func (h *DispatchHandler) Handle(ctx context.Context, sessionKey string, msg bot.InboundMessage) (string, error) {
	if reply, ok := h.maybeHandleAdminCommand(sessionKey, msg.Text); ok {
		return reply, nil
	}

	slog.Debug("handler: dispatching to session manager", "session", sessionKey)
	userID := bot.UserID(msg.ChatID, msg.SenderID)
	reply, err := h.Mgr.Dispatch(ctx, sessionKey, userID, msg.Text)
	if err != nil {
		if errors.Is(err, resilience.ErrCircuitOpen) {
			return "I'm sorry, I'm currently having trouble connecting to one of my services. Please try again in a few moments.", nil
		}
		return "", fmt.Errorf("dispatch session: %w", err)
	}
	if h.Memory != nil {
		h.indexMemory(sessionKey, msg.Text, reply)
	}
	if h.Consolidator != nil && reply != "" {
		h.Consolidator.ConsolidateAsync(sessionKey, reply)
	}
	return reply, nil
}

func (h *DispatchHandler) maybeHandleAdminCommand(sessionKey, text string) (string, bool) {
	if strings.TrimSpace(text) == "/reset_circuits" {
		resilience.ResetAll()
		slog.Info("resilience: all circuit breakers reset by user", "session", sessionKey)
		return "All circuit breakers have been reset.", true
	}
	return "", false
}

func (h *DispatchHandler) indexMemory(sessionKey, userMsg, assistantReply string) {
	if memory.ShouldSkipRAG(userMsg) {
		return
	}
	ns := "session:" + sessionKey
	_ = h.Memory.Index(ns, "USER: "+userMsg)
	if assistantReply != "" {
		if indexErr := h.Memory.Index(ns, "ASSISTANT: "+assistantReply); indexErr != nil {
			slog.Warn("memory: index failed", "session", sessionKey, "err", indexErr)
		}
	}
}

func (h *DispatchHandler) HandleCallback(ctx context.Context, cb bot.InboundCallback) error {
	if h.Hitl != nil {
		if err := h.Hitl.HandleCallback(ctx, cb); err != nil {
			return fmt.Errorf("hitl callback: %w", err)
		}
	}
	return nil
}
