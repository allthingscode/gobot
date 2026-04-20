package app

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/memory"
	"github.com/allthingscode/gobot/internal/provider"
)

const (
	spawnToolName      = "spawn_subagent"
	spawnMaxTimeout    = 5 * time.Minute
	spawnMaxIterations = 5
)

// SpawnTool implements Tool and enables the main agent to delegate complex
// tasks to ephemeral, specialized sub-agents (F-001).
type SpawnTool struct {
	RunnerFactory     func(model, systemPrompt string) agent.Runner
	Model             string
	SpecialistPrompts map[string]string
	SpecialistModels  map[string]string
	MemStore          *memory.MemoryStore
	Cfg               *config.Config
}

type iterLimitRunner struct {
	Inner agent.Runner
	Max   int
	Count int
}

func (r *iterLimitRunner) SetMaxToolIterations(n int) {
	if c, ok := r.Inner.(ToolLimitConfigurable); ok {
		c.SetMaxToolIterations(n)
	}
}

func (r *iterLimitRunner) RunText(ctx context.Context, sessionKey, prompt, modelOverride string) (string, error) {
	resp, err := r.Inner.RunText(ctx, sessionKey, prompt, modelOverride)
	if err != nil {
		return "", fmt.Errorf("run text: %w", err)
	}
	return resp, nil
}

func (r *iterLimitRunner) Run(ctx context.Context, sessionKey, userID string, messages []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error) {
	r.Count++
	if r.Count > r.Max {
		return "", nil, fmt.Errorf("spawn: sub-agent exceeded maximum iterations (%d)", r.Max)
	}
	resp, msgs, err := r.Inner.Run(ctx, sessionKey, userID, messages)
	if err != nil {
		return "", nil, fmt.Errorf("run: %w", err)
	}
	return resp, msgs, nil
}

// newSpawnTool creates a SpawnTool that builds sub-runners from a provider.
func newSpawnTool(prov provider.Provider, model string, specialistPrompts, specialistModels map[string]string, memStore *memory.MemoryStore, cfg *config.Config) *SpawnTool {
	return &SpawnTool{
		RunnerFactory: func(m, systemPrompt string) agent.Runner {
			runner := NewAgentRunner(prov, m, systemPrompt, cfg)
			runner.MemStore = memStore
			return runner
		},
		Model:             model,
		SpecialistPrompts: specialistPrompts,
		SpecialistModels:  specialistModels,
		MemStore:          memStore,
		Cfg:               cfg,
	}
}

func (s *SpawnTool) Name() string { return spawnToolName }

type spawnArgs struct {
	AgentType string `json:"agent_type" schema:"The specialist type to spawn. Options: 'researcher' (fact-finding, web research), 'analyst' (data/situation analysis), 'writer' (drafting content)."`
	Objective string `json:"objective" schema:"The specific, self-contained task or question for the sub-agent to complete. Be explicit -- the sub-agent has no conversation context. Required."`
}

func (s *SpawnTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{
		Name:        spawnToolName,
		Description: "Delegate a complex or research-heavy task to a specialized sub-agent that works independently and returns a structured summary. Use this when a task would saturate your context window or benefits from a separate focused agent (e.g. deep research, drafting a long document, multi-step analysis).",
		Parameters:  agent.DeriveSchema(spawnArgs{}),
	}
}

func (t *SpawnTool) Execute(ctx context.Context, sessionKey, userID string, args map[string]any) (string, error) {
	agentType, _ := args["agent_type"].(string)
	objective, _ := args["objective"].(string)

	if objective == "" {
		return "", fmt.Errorf("spawn: objective is required")
	}
	if agentType == "" {
		agentType = RoleResearcher
	}

	systemPrompt := t.SpecialistPrompts[agentType]
	if systemPrompt == "" {
		systemPrompt = DefaultSpecialistPrompt(agentType)
	}

	model := t.SpecialistModels[agentType]
	if model == "" {
		model = t.Model
	}

	subRunner := t.RunnerFactory(model, systemPrompt)

	if c, ok := subRunner.(ToolLimitConfigurable); ok {
		c.SetMaxToolIterations(spawnMaxIterations)
	}

	limitedRunner := &iterLimitRunner{Inner: subRunner, Max: spawnMaxIterations}
	subMgr := agent.NewSessionManager(limitedRunner, nil, model)

	subKey := fmt.Sprintf("agent:%s:%s", agentType, sessionKey)
	start := time.Now()
	slog.Info("spawn: starting sub-agent", "type", agentType, "model", model, "parent", sessionKey, "subKey", subKey)

	subCtx, cancel := context.WithTimeout(ctx, spawnMaxTimeout)
	defer cancel()

	reply, err := subMgr.Dispatch(subCtx, subKey, userID, objective)
	elapsed := time.Since(start)
	if err != nil {
		slog.Error("spawn: sub-agent failed", "subKey", subKey, "model", model, "elapsed", elapsed, "err", err)
		return "", fmt.Errorf("spawn %s: %w", agentType, err)
	}
	slog.Info("spawn: sub-agent complete", "subKey", subKey, "model", model, "elapsed", elapsed, "replyLen", len(reply), "iterations", limitedRunner.Count)
	return reply, nil
}

// DefaultSpecialistPrompt returns the default system prompt for a given agent type.
func DefaultSpecialistPrompt(agentType string) string {
	switch agentType {
	case RoleResearcher:
		return "You are a focused research specialist. Research the given topic thoroughly using available search tools and return a concise, factual, well-structured report. Do not ask clarifying questions -- work with what you have and deliver your best findings."
	case RoleAnalyst:
		return "You are a strategic analyst. Analyze the given data or situation and return actionable insights in a structured format. Be direct and evidence-based. Do not ask clarifying questions -- deliver your analysis."
	case RoleWriter:
		return "You are a professional writer and editor. Produce clear, well-structured content based on the given objective. Deliver the final written output directly without preamble."
	default:
		return "You are a specialized sub-agent. Complete the given objective thoroughly and return a structured summary of your findings. Be concise and direct."
	}
}
