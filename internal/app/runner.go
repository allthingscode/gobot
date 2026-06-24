package app

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"golang.org/x/time/rate"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/memory"
	"github.com/allthingscode/gobot/internal/memory/vector"
	"github.com/allthingscode/gobot/internal/observability"
	"github.com/allthingscode/gobot/internal/provider"
	"github.com/allthingscode/gobot/internal/resilience"
)

// ToolLimitConfigurable is an optional interface that runners can implement
// to allow the tool to set their internal iteration limit.
type ToolLimitConfigurable interface {
	SetMaxToolIterations(int)
}

// AgentRunner implements the agent.Runner interface using a provider.Provider.
type AgentRunner struct {
	Prov                provider.Provider
	Model               string
	SystemPrompt        string
	MemStore            *memory.MemoryStore                     // may be nil; shared single-user RAG store
	MemStoreProvider    func(userID string) *memory.MemoryStore // may be nil; F-105 per-user store factory
	VecStore            *vector.Store                           // F-030: Semantic memory
	EmbedProv           vector.EmbeddingProvider                // F-030: Semantic memory
	Cfg                 *config.Config                          // F-030: Configuration
	ToolsByName         map[string]Tool                         // registered tools exposed to the provider
	Breaker             *resilience.Breaker                     // circuit breaker for API calls
	Limiter             *rate.Limiter                           // token-bucket rate limiter
	Hooks               *agent.Hooks                            // may be nil; set via SetHooks
	Tracer              *observability.DispatchTracer
	IdempStore          *agentctx.IdempotencyStore // may be nil; idempotency for side-effecting tools
	SideEffectingTools  map[string]bool            // C-142: lookup for tools that modify external state
	MaxToolIterations   int
	MaxTokens           int
	MaxToolResultBytes  int
	EnableReflection    bool // opt-in; off by default for cost control
	MaxReflectionRounds int  // default 1 â†’ â‰¤2x token overhead
}

// NewAgentRunner creates a new AgentRunner for the given provider and model.
func NewAgentRunner(prov provider.Provider, model, systemPrompt string, cfg *config.Config) *AgentRunner {
	maxFail, window, timeout := cfg.Breaker(prov.Name())
	return &AgentRunner{
		Prov:                prov,
		Model:               model,
		SystemPrompt:        systemPrompt,
		Cfg:                 cfg,
		Breaker:             resilience.New(prov.Name(), maxFail, window, timeout),
		Limiter:             rate.NewLimiter(rate.Every(time.Second), 3),
		MaxToolIterations:   cfg.EffectiveMaxToolIterations(),
		MaxTokens:           cfg.MaxTokens(),
		MaxToolResultBytes:  cfg.MaxToolResultBytes(),
		EnableReflection:    false,
		MaxReflectionRounds: 1,
	}
}

// RunText performs a single-turn, text-only LLM call without tool use.
func (r *AgentRunner) RunText(ctx context.Context, sessionKey, prompt, modelOverride string) (string, error) {
	model := r.Model
	if modelOverride != "" {
		model = modelOverride
	}
	req := provider.ChatRequest{
		Model:    model,
		Messages: []agentctx.StrategicMessage{{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: &prompt}}},
	}
	resp, err := r.RetryChat(ctx, sessionKey, req)
	if err != nil {
		return "", fmt.Errorf("RunText: %w", err)
	}
	return ExtractText(resp.Message), nil
}

// SetHooks configures lifecycle hooks for this runner.
func (r *AgentRunner) SetHooks(h *agent.Hooks) {
	r.Hooks = h
}

// SetTracer configures the observability tracer for this runner.
func (r *AgentRunner) SetTracer(t *observability.DispatchTracer) {
	r.Tracer = t
}

// SetIdempotencyStore configures the idempotency store for side-effecting tools.
func (r *AgentRunner) SetIdempotencyStore(store *agentctx.IdempotencyStore) {
	r.IdempStore = store
}

// SetMemoryStoreProvider configures a factory that returns a per-user MemoryStore.
func (r *AgentRunner) SetMemoryStoreProvider(fn func(userID string) *memory.MemoryStore) {
	r.MemStoreProvider = fn
}

// SetMaxToolIterations sets the maximum number of tool call turns allowed in a single Run.
func (r *AgentRunner) SetMaxToolIterations(n int) {
	r.MaxToolIterations = n
}

// SetTools registers a list of tools with the runner.
func (r *AgentRunner) SetTools(tools []Tool) {
	m := make(map[string]Tool, len(tools))
	se := make(map[string]bool)
	for _, t := range tools {
		decl := t.Declaration()
		name := decl.Name
		if _, dup := m[name]; dup {
			slog.Warn("runner: duplicate tool name registered, later registration wins", "tool", name)
		}
		m[name] = t
		if decl.SideEffecting {
			se[name] = true
		}
	}
	r.ToolsByName = m
	r.SideEffectingTools = se
}

// Run executes the tool-call/response loop until the provider returns a terminal text response.
func (r *AgentRunner) Run(ctx context.Context, sessionKey, userID string, messages []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error) {
	memStore := r.MemStore
	if r.MemStoreProvider != nil && userID != "" {
		memStore = r.MemStoreProvider(userID)
	}

	sysPrompt := r.buildSystemPrompt(ctx, sessionKey, messages, memStore)
	userText := LastUserText(messages)
	rubric := r.generateReflectionRubric(ctx, sessionKey, userText)

	toolDecls := make([]provider.ToolDeclaration, 0, len(r.ToolsByName))
	for _, t := range r.ToolsByName {
		toolDecls = append(toolDecls, t.Declaration())
	}

	toolSeq := make([]string, 0, r.MaxToolIterations*2)
	reflectionRounds := 0

	for iter := 0; iter < r.MaxToolIterations; iter++ {
		req := provider.ChatRequest{
			Model:             r.Model,
			Messages:          messages,
			SystemInstruction: sysPrompt,
			Tools:             toolDecls,
			MaxTokens:         r.MaxTokens,
		}

		slog.Debug("runner: calling provider.Chat", "session", sessionKey, "provider", r.Prov.Name(), "model", r.Model, "messages", len(messages), "iter", iter)

		resp, err := r.RetryChat(ctx, sessionKey, req)
		if err != nil {
			return "", nil, fmt.Errorf("chat: %w", err)
		}

		messages = append(messages, resp.Message)

		if len(resp.Message.ToolCalls) == 0 {
			text, done := r.handleTerminalResponse(ctx, sessionKey, userText, rubric, resp.Message, &messages, &reflectionRounds)
			if done {
				return text, messages, nil
			}
			continue
		}

		newMsgs, err := r.processToolCalls(ctx, sessionKey, userID, resp.Message.ToolCalls, iter, &toolSeq)
		if err != nil {
			return "", nil, err
		}
		messages = append(messages, newMsgs...)
	}

	slog.Error("runner: tool loop exhausted",
		"session", sessionKey,
		"iterations", r.MaxToolIterations,
		"tool_sequence", strings.Join(toolSeq, " -> "),
	)
	return "", nil, fmt.Errorf("runner: tool dispatch loop exceeded %d iterations", r.MaxToolIterations)
}
