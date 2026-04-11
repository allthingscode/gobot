package provider

import (
	"context"
	"log/slog"
	"strings"

	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/config"
)

// RoutingProvider implements the Provider interface by delegating to a cheap
// manager model for classification and simple turns, escalating to a specialist
// executor model only when tool use or complex reasoning is required.
type RoutingProvider struct {
	executor Provider
	manager  Provider
	cfg      config.RoutingConfig
}

// NewRoutingProvider creates a new RoutingProvider wrapping the given models.
func NewRoutingProvider(executor, manager Provider, cfg config.RoutingConfig) *RoutingProvider {
	return &RoutingProvider{
		executor: executor,
		manager:  manager,
		cfg:      cfg,
	}
}

// Name returns "routing" followed by the underlying provider names.
func (p *RoutingProvider) Name() string {
	return "routing(" + p.manager.Name() + "->" + p.executor.Name() + ")"
}

// Models returns the union of models supported by both providers.
func (p *RoutingProvider) Models() []ModelInfo {
	return append(p.executor.Models(), p.manager.Models()...)
}

// Chat implements the routing logic.
func (p *RoutingProvider) Chat(ctx context.Context, req ChatRequest) (*ChatResponse, error) {
	if !p.cfg.Enabled {
		return p.executor.Chat(ctx, req)
	}

	// 1. Heuristic: If no tools and short message, use manager directly.
	lastMsg := ""
	if len(req.Messages) > 0 {
		lastMsg = req.Messages[len(req.Messages)-1].Content.String()
	}

	if len(req.Tools) == 0 && len(lastMsg) < 100 {
		slog.Debug("routing: bypass classification (conversational)", "manager", p.cfg.ManagerModel)
		return p.managerChat(ctx, req)
	}

	// 2. Classification Turn
	classifyReq := ChatRequest{
		Model: p.cfg.ManagerModel,
		SystemInstruction: "Does the user message require tool execution, deep technical analysis, or complex reasoning? Reply ONLY with 'YES' or 'NO'.",
		Messages: []agentctx.StrategicMessage{
			{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: &lastMsg}},
		},
	}

	resp, err := p.manager.Chat(ctx, classifyReq)
	if err != nil {
		slog.Warn("routing: classification failed, falling back to executor", "err", err)
		return p.executorChat(ctx, req)
	}

	decision := strings.TrimSpace(resp.Message.Content.String())
	slog.Info("routing: classification result", "decision", decision, "model", p.cfg.ManagerModel)

	if strings.ToUpper(decision) == "YES" {
		return p.executorChat(ctx, req)
	}

	// Decision is NO or ambiguous
	if strings.ToUpper(decision) != "NO" {
		slog.Warn("routing: ambiguous classification result, falling back to executor", "raw", decision)
		return p.executorChat(ctx, req)
	}

	return p.managerChat(ctx, req)
}

func (p *RoutingProvider) managerChat(ctx context.Context, req ChatRequest) (*ChatResponse, error) {
	slog.Info("routing: turn handled by manager", "model", p.cfg.ManagerModel)
	
	// Create a copy of the request but use the manager model and NO tools.
	mReq := req
	mReq.Model = p.cfg.ManagerModel
	mReq.Tools = nil

	return p.manager.Chat(ctx, mReq)
}

func (p *RoutingProvider) executorChat(ctx context.Context, req ChatRequest) (*ChatResponse, error) {
	slog.Info("routing: turn handled by executor", "model", req.Model)
	return p.executor.Chat(ctx, req)
}
