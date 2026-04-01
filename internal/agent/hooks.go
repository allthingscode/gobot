package agent

import (
	"context"

	agentctx "github.com/allthingscode/gobot/internal/context"
)

// PostToolFn transforms a tool's string result after execution but before it
// is returned to the agent. Hooks run in registration order; each receives
// the output of the previous.
type PostToolFn func(ctx context.Context, toolName string, result string) string

// PreToolFn allows a hook to intercept tool execution. If it returns a non-empty
// string, that string is used as the tool result and the execution is skipped.
// If it returns an error, the entire tool loop is aborted.
type PreToolFn func(ctx context.Context, sessionKey string, toolName string, args map[string]any) (string, error)

// PreHistoryFn transforms the conversation history before it is passed to the
// runner. Hooks run in registration order; each receives the output of the previous.
type PreHistoryFn func(ctx context.Context, messages []agentctx.StrategicMessage) []agentctx.StrategicMessage

// PrePromptFn transforms the system prompt before each Gemini call.
// Hooks run in registration order; each receives the output of the previous.
type PrePromptFn func(ctx context.Context, systemPrompt string) string

// Hooks holds ordered lists of lifecycle hook functions.
// The zero value is ready to use (no hooks registered).
// Hooks is not safe for concurrent Register calls; register all hooks at
// startup before the first Dispatch call.
type Hooks struct {
	preHistory []PreHistoryFn
	prePrompt  []PrePromptFn
	postTool   []PostToolFn
	preTool    []PreToolFn
}

// RegisterPreHistory appends fn to the PreHistory chain.
func (h *Hooks) RegisterPreHistory(fn PreHistoryFn) {
	h.preHistory = append(h.preHistory, fn)
}

// RegisterPrePrompt appends fn to the PrePrompt chain.
func (h *Hooks) RegisterPrePrompt(fn PrePromptFn) {
	h.prePrompt = append(h.prePrompt, fn)
}

// RegisterPreTool appends fn to the PreTool chain.
func (h *Hooks) RegisterPreTool(fn PreToolFn) {
	h.preTool = append(h.preTool, fn)
}

// RunPreHistory runs all registered PreHistory hooks in order.
// Returns messages unchanged if no hooks are registered.
func (h *Hooks) RunPreHistory(ctx context.Context, messages []agentctx.StrategicMessage) []agentctx.StrategicMessage {
	for _, fn := range h.preHistory {
		messages = fn(ctx, messages)
	}
	return messages
}

// RunPrePrompt runs all registered PrePrompt hooks in order.
// Returns prompt unchanged if no hooks are registered.
func (h *Hooks) RunPrePrompt(ctx context.Context, prompt string) string {
	for _, fn := range h.prePrompt {
		prompt = fn(ctx, prompt)
	}
	return prompt
}

// RunPreTool runs all registered PreTool hooks in order.
// Returns the first non-empty result or nil error if all hooks pass.
func (h *Hooks) RunPreTool(ctx context.Context, sessionKey, toolName string, args map[string]any) (string, error) {
	for _, fn := range h.preTool {
		result, err := fn(ctx, sessionKey, toolName, args)
		if err != nil {
			return "", err
		}
		if result != "" {
			return result, nil
		}
	}
	return "", nil
}

// RegisterPostTool appends fn to the PostTool chain.
func (h *Hooks) RegisterPostTool(fn PostToolFn) {
	h.postTool = append(h.postTool, fn)
}

// RunPostTool runs all registered PostTool hooks in order.
// Returns result unchanged if no hooks are registered.
func (h *Hooks) RunPostTool(ctx context.Context, toolName, result string) string {
	for _, fn := range h.postTool {
		result = fn(ctx, toolName, result)
	}
	return result
}
