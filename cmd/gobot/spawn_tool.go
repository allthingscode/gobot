package main

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"google.golang.org/genai"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/memory"
)

const (
	spawnToolName    = "spawn_subagent"
	spawnMaxTimeout  = 5 * time.Minute
)

// SpawnTool implements Tool and enables the main agent to delegate complex
// tasks to ephemeral, specialized sub-agents (F-001).
//
// A sub-agent is a fresh SessionManager (no checkpoint store) backed by a
// new geminiRunner with a specialized system prompt. It runs in the same
// goroutine as the tool call and times out after spawnMaxTimeout.
//
// Sub-agent session keys: "agent:<agent_type>:<parent_session_key>"
type SpawnTool struct {
	// runnerFactory creates a new Runner for the given system prompt.
	// Using a factory keeps SpawnTool testable without a live Gemini client.
	runnerFactory func(systemPrompt string) agent.Runner

	// model is passed to NewSessionManager for traceability.
	model string

	// specialistPrompts maps agent_type -> system prompt override.
	// Falls back to defaultSpecialistPrompt when absent.
	specialistPrompts map[string]string

	// memStore is optional; if set, sub-agents get RAG context too.
	memStore *memory.MemoryStore
}

// newSpawnTool creates a SpawnTool that builds sub-runners from client/model.
func newSpawnTool(client *genai.Client, model string, specialistPrompts map[string]string, memStore *memory.MemoryStore) *SpawnTool {
	return &SpawnTool{
		runnerFactory: func(systemPrompt string) agent.Runner {
			r := newGeminiRunner(client, model, systemPrompt)
			r.memStore = memStore
			return r
		},
		model:             model,
		specialistPrompts: specialistPrompts,
		memStore:          memStore,
	}
}

func (s *SpawnTool) Name() string { return spawnToolName }

func (s *SpawnTool) Declaration() *genai.FunctionDeclaration {
	return &genai.FunctionDeclaration{
		Name:        spawnToolName,
		Description: "Delegate a complex or research-heavy task to a specialized sub-agent that works independently and returns a structured summary. Use this when a task would saturate your context window or benefits from a separate focused agent (e.g. deep research, drafting a long document, multi-step analysis).",
		Parameters: &genai.Schema{
			Type: genai.TypeObject,
			Properties: map[string]*genai.Schema{
				"agent_type": {
					Type:        genai.TypeString,
					Description: "The specialist type to spawn. Options: 'researcher' (fact-finding, web research), 'analyst' (data/situation analysis), 'writer' (drafting content).",
				},
				"objective": {
					Type:        genai.TypeString,
					Description: "The specific, self-contained task or question for the sub-agent to complete. Be explicit — the sub-agent has no conversation context.",
				},
			},
			Required: []string{"agent_type", "objective"},
		},
	}
}

func (s *SpawnTool) Execute(ctx context.Context, parentSessionKey string, args map[string]any) (string, error) {
	agentType, _ := args["agent_type"].(string)
	objective, _ := args["objective"].(string)

	if objective == "" {
		return "", fmt.Errorf("spawn: objective is required")
	}
	if agentType == "" {
		agentType = "researcher"
	}

	systemPrompt := s.specialistPrompts[agentType]
	if systemPrompt == "" {
		systemPrompt = defaultSpecialistPrompt(agentType)
	}

	subRunner := s.runnerFactory(systemPrompt)
	// Sub-agents are ephemeral — no checkpoint store.
	subMgr := agent.NewSessionManager(subRunner, nil, s.model)

	subKey := fmt.Sprintf("agent:%s:%s", agentType, parentSessionKey)

	subCtx, cancel := context.WithTimeout(ctx, spawnMaxTimeout)
	defer cancel()

	slog.Info("spawn: starting sub-agent", "type", agentType, "parent", parentSessionKey, "subKey", subKey)
	reply, err := subMgr.Dispatch(subCtx, subKey, objective)
	if err != nil {
		return "", fmt.Errorf("spawn %s: %w", agentType, err)
	}
	slog.Info("spawn: sub-agent complete", "subKey", subKey, "replyLen", len(reply))
	return reply, nil
}

// defaultSpecialistPrompt returns a built-in system prompt for known agent types.
func defaultSpecialistPrompt(agentType string) string {
	switch agentType {
	case "researcher":
		return "You are a focused research specialist. Research the given topic thoroughly using available search tools and return a concise, factual, well-structured report. Do not ask clarifying questions — work with what you have and deliver your best findings."
	case "analyst":
		return "You are a strategic analyst. Analyze the given data or situation and return actionable insights in a structured format. Be direct and evidence-based. Do not ask clarifying questions — deliver your analysis."
	case "writer":
		return "You are a professional writer and editor. Produce clear, well-structured content based on the given objective. Deliver the final written output directly without preamble."
	default:
		return "You are a specialized sub-agent. Complete the given objective thoroughly and return a structured summary of your findings. Be concise and direct."
	}
}
