package main

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
//
// A sub-agent is a fresh SessionManager (no checkpoint store) backed by a
// new geminiRunner with a specialized system prompt. It runs in the same
// goroutine as the tool call and times out after spawnMaxTimeout.
//
// Sub-agent session keys: "agent:<agent_type>:<parent_session_key>".
type SpawnTool struct {
	// runnerFactory creates a new Runner for the given model and system prompt.
	// Using a factory keeps SpawnTool testable without a live LLM provider.
	runnerFactory func(model, systemPrompt string) agent.Runner

	// model is the default model used when no specialist override is configured.
	model string

	// specialistPrompts maps agent_type -> system prompt override.
	// Falls back to defaultSpecialistPrompt when absent.
	specialistPrompts map[string]string

	// specialistModels maps agent_type -> model override.
	// Falls back to s.model when absent.
	specialistModels map[string]string

	// memStore is optional; if set, sub-agents get RAG context too.
	memStore *memory.MemoryStore

	// cfg is required to create sub-runners with the correct settings (F-054).
	cfg *config.Config
}

// iterLimitRunner wraps a Runner and enforces a maximum number of Run calls.
// Each call increments count; when count exceeds max, Run returns an error without
// calling inner. This prevents sub-agents from looping indefinitely.
type iterLimitRunner struct {
	inner agent.Runner
	max   int
	count int
}

func (r *iterLimitRunner) RunText(ctx context.Context, sessionKey, prompt, modelOverride string) (string, error) {
	return r.inner.RunText(ctx, sessionKey, prompt, modelOverride)
}

func (r *iterLimitRunner) Run(ctx context.Context, sessionKey, userID string, messages []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error) {
	r.count++
	if r.count > r.max {
		return "", nil, fmt.Errorf("spawn: sub-agent exceeded maximum iterations (%d)", r.max)
	}
	return r.inner.Run(ctx, sessionKey, userID, messages)
}

// newSpawnTool creates a SpawnTool that builds sub-runners from a provider.
func newSpawnTool(prov provider.Provider, model string, specialistPrompts, specialistModels map[string]string, memStore *memory.MemoryStore, cfg *config.Config) *SpawnTool {
	return &SpawnTool{
		runnerFactory: func(m, systemPrompt string) agent.Runner {
			runner := newGeminiRunner(prov, m, systemPrompt, cfg)
			runner.memStore = memStore
			return runner
		},
		model:             model,
		specialistPrompts: specialistPrompts,
		specialistModels:  specialistModels,
		memStore:          memStore,
		cfg:               cfg,
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
		agentType = "researcher" //nolint:goconst // specialist default
	}

	systemPrompt := t.specialistPrompts[agentType]
	if systemPrompt == "" {
		systemPrompt = defaultSpecialistPrompt(agentType)
	}

	// Resolve model: specialist override -> default.
	model := t.specialistModels[agentType]
	if model == "" {
		model = t.model
	}

	subRunner := t.runnerFactory(model, systemPrompt)
	// Wrap in an iteration limiter (F-001: max 5 iterations to prevent infinite loops).
	limitedRunner := &iterLimitRunner{inner: subRunner, max: spawnMaxIterations}
	// Sub-agents are ephemeral -- no checkpoint store.
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
	slog.Info("spawn: sub-agent complete", "subKey", subKey, "model", model, "elapsed", elapsed, "replyLen", len(reply), "iterations", limitedRunner.count)
	return reply, nil
}

// defaultSpecialistPrompt returns a built-in system prompt for known agent types.
func defaultSpecialistPrompt(agentType string) string {
	switch agentType {
	case "researcher":
		return "You are a focused research specialist. Research the given topic thoroughly using available search tools and return a concise, factual, well-structured report. Do not ask clarifying questions -- work with what you have and deliver your best findings."
	case "analyst":
		return "You are a strategic analyst. Analyze the given data or situation and return actionable insights in a structured format. Be direct and evidence-based. Do not ask clarifying questions -- deliver your analysis."
	case "writer":
		return "You are a professional writer and editor. Produce clear, well-structured content based on the given objective. Deliver the final written output directly without preamble."
	default:
		return "You are a specialized sub-agent. Complete the given objective thoroughly and return a structured summary of your findings. Be concise and direct."
	}
}
