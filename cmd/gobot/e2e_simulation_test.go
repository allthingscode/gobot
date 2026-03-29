package main

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"google.golang.org/genai"

	"github.com/allthingscode/gobot/internal/agent"
	agentctx "github.com/allthingscode/gobot/internal/context"
)

// Scenario defines a complete conversation test case.
type Scenario struct {
	Name       string     // human-readable test name
	UserPrompt string     // the initial user message
	Steps      []SimStep  // scripted "Gemini" turns, executed in order
	WantCalls  []WantCall // assertions on tool invocations
	WantReply  string     // substring that must appear in the final reply (empty = skip check)
}

// SimStep is one scripted "Gemini" turn.
// If ToolCalls is non-empty, the runner dispatches them before advancing.
// The last step should have ToolCalls empty and FinalText non-empty.
type SimStep struct {
	ToolCalls []SimToolCall // tool calls Gemini "decides" to make this turn
	FinalText string        // Gemini's final text response (only used when ToolCalls is empty)
}

// SimToolCall is a scripted function call from "Gemini".
type SimToolCall struct {
	Name string
	Args map[string]any
}

// WantCall asserts a specific tool invocation was recorded.
type WantCall struct {
	ToolName string // required; must match a recorded tool call name
	ArgKey   string // optional; if non-empty, check this arg
	ArgValue string // optional; substring match against fmt.Sprint(args[ArgKey])
}

// ToolCallRecord captures one tool invocation during simulation.
type ToolCallRecord struct {
	Name   string
	Args   map[string]any
	Result string
	Err    error
}

// simRunner implements agent.Runner using scripted steps.
// It executes scripted tool calls against registered tools and returns
// a scripted final text, recording every tool invocation.
type simRunner struct {
	steps    []SimStep
	tools    []Tool
	recorded []ToolCallRecord
	stepIdx  int
}

func (r *simRunner) Run(ctx context.Context, sessionKey string, messages []agentctx.StrategicMessage) (string, []agentctx.StrategicMessage, error) {
	for r.stepIdx < len(r.steps) {
		step := r.steps[r.stepIdx]
		r.stepIdx++

		if len(step.ToolCalls) == 0 {
			// Final text step — return the scripted response.
			text := step.FinalText
			updated := append(messages, agentctx.StrategicMessage{
				Role:    "assistant",
				Content: &agentctx.MessageContent{Str: &text},
			})
			return text, updated, nil
		}

		// Tool-call step — dispatch each call to registered tools.
		for _, fc := range step.ToolCalls {
			result, err := r.dispatchTool(ctx, sessionKey, fc)
			r.recorded = append(r.recorded, ToolCallRecord{
				Name:   fc.Name,
				Args:   fc.Args,
				Result: result,
				Err:    err,
			})
		}
	}
	return "", nil, fmt.Errorf("simulation: no final-text step found after %d steps", len(r.steps))
}

// dispatchTool finds the registered tool by name and executes it.
// If no tool matches, returns a placeholder string (not an error).
func (r *simRunner) dispatchTool(ctx context.Context, sessionKey string, fc SimToolCall) (string, error) {
	for _, t := range r.tools {
		if t.Name() == fc.Name {
			return t.Execute(ctx, sessionKey, fc.Args)
		}
	}
	return fmt.Sprintf("[tool %q not registered in scenario]", fc.Name), nil
}

// simTool is a lightweight mock implementation of Tool for use in scenarios.
type simTool struct {
	name     string
	response string
	err      error
}

func (t *simTool) Name() string { return t.name }

func (t *simTool) Declaration() *genai.FunctionDeclaration {
	return &genai.FunctionDeclaration{Name: t.name, Description: "mock tool for simulation"}
}

func (t *simTool) Execute(_ context.Context, _ string, _ map[string]any) (string, error) {
	if t.err != nil {
		return "", t.err
	}
	return t.response, nil
}

// RunScenario wires up a SessionManager with the scenario's scripted runner and
// registered tools, dispatches the user prompt, and asserts all WantCalls and
// WantReply constraints. Fails the test immediately on dispatch error.
func RunScenario(t *testing.T, s Scenario, tools []Tool) {
	t.Helper()

	runner := &simRunner{steps: s.Steps, tools: tools}
	mgr := agent.NewSessionManager(runner, nil, "sim-model")

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	reply, err := mgr.Dispatch(ctx, "e2e:"+s.Name, s.UserPrompt)
	if err != nil {
		t.Fatalf("[%s] Dispatch error: %v", s.Name, err)
	}

	// Assert final reply contains the expected substring.
	if s.WantReply != "" && !strings.Contains(reply, s.WantReply) {
		t.Errorf("[%s] reply %q does not contain %q", s.Name, reply, s.WantReply)
	}

	// Assert each wanted tool call was recorded.
	for _, want := range s.WantCalls {
		found := false
		for _, rec := range runner.recorded {
			if rec.Name != want.ToolName {
				continue
			}
			if want.ArgKey == "" {
				found = true
				break
			}
			if v, ok := rec.Args[want.ArgKey]; ok {
				if strings.Contains(fmt.Sprint(v), want.ArgValue) {
					found = true
					break
				}
			}
		}
		if !found {
			t.Errorf("[%s] expected tool call %q with arg %q=%q not found; recorded: %+v",
				s.Name, want.ToolName, want.ArgKey, want.ArgValue, runner.recorded)
		}
	}
}

func TestE2ESimulation_DirectResponse(t *testing.T) {
	RunScenario(t, Scenario{
		Name:       "direct_response",
		UserPrompt: "What is 2 + 2?",
		Steps: []SimStep{
			{FinalText: "2 + 2 equals 4."},
		},
		WantReply: "4",
	}, nil)
}

func TestE2ESimulation_SingleToolCall(t *testing.T) {
	calendarTool := &simTool{
		name:     "list_calendar_events",
		response: "Monday 9am: Team standup\nWednesday 2pm: Design review",
	}

	RunScenario(t, Scenario{
		Name:       "single_tool_call",
		UserPrompt: "What's on my calendar?",
		Steps: []SimStep{
			{
				ToolCalls: []SimToolCall{
					{Name: "list_calendar_events", Args: map[string]any{"max_results": float64(5)}},
				},
			},
			{FinalText: "You have a standup Monday and a design review Wednesday."},
		},
		WantCalls: []WantCall{
			{ToolName: "list_calendar_events"},
		},
		WantReply: "standup",
	}, []Tool{calendarTool})
}

func TestE2ESimulation_MultiStep(t *testing.T) {
	calendarTool := &simTool{
		name:     "list_calendar_events",
		response: "Friday 3pm: Sprint review",
	}
	emailTool := &simTool{
		name:     "send_email",
		response: "Email sent successfully.",
	}

	RunScenario(t, Scenario{
		Name:       "multi_step",
		UserPrompt: "Check my calendar and send me a summary by email.",
		Steps: []SimStep{
			{
				ToolCalls: []SimToolCall{
					{Name: "list_calendar_events", Args: map[string]any{"max_results": float64(3)}},
				},
			},
			{
				ToolCalls: []SimToolCall{
					{Name: "send_email", Args: map[string]any{
						"subject": "Your Weekly Schedule",
						"body":    "Sprint review on Friday at 3pm.",
					}},
				},
			},
			{FinalText: "Done! I've sent you a summary of your upcoming events."},
		},
		WantCalls: []WantCall{
			{ToolName: "list_calendar_events"},
			{ToolName: "send_email", ArgKey: "subject", ArgValue: "Schedule"},
		},
		WantReply: "summary",
	}, []Tool{calendarTool, emailTool})
}

func TestE2ESimulation_ToolError(t *testing.T) {
	failingTool := &simTool{
		name: "list_calendar_events",
		err:  fmt.Errorf("calendar service unavailable"),
	}

	RunScenario(t, Scenario{
		Name:       "tool_error",
		UserPrompt: "What's on my calendar?",
		Steps: []SimStep{
			{
				ToolCalls: []SimToolCall{
					{Name: "list_calendar_events", Args: map[string]any{}},
				},
			},
			{FinalText: "Sorry, I couldn't reach your calendar right now."},
		},
		WantCalls: []WantCall{
			{ToolName: "list_calendar_events"},
		},
		WantReply: "couldn't reach",
	}, []Tool{failingTool})
}

func TestE2ESimulation_NoSteps(t *testing.T) {
	runner := &simRunner{steps: nil, tools: nil}
	mgr := agent.NewSessionManager(runner, nil, "sim-model")

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := mgr.Dispatch(ctx, "e2e:no_steps", "hello")
	if err == nil {
		t.Fatal("expected error when scenario has no steps, got nil")
	}
}
