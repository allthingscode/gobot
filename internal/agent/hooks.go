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

// PostDispatchFn transforms the agent's final response string after a successful
// Dispatch, but before it is returned to the caller.
type PostDispatchFn func(ctx context.Context, sessionKey string, response string) string

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
	preHistory   []PreHistoryFn
	prePrompt    []PrePromptFn
	postTool     []PostToolFn
	preTool      []PreToolFn
	postDispatch []PostDispatchFn
}

// RegisterPostDispatch appends fn to the PostDispatch chain.
func (h *Hooks) RegisterPostDispatch(fn PostDispatchFn) {
	h.postDispatch = append(h.postDispatch, fn)
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

// HasPreHistory returns true if at least one PreHistory hook is registered.
func (h *Hooks) HasPreHistory() bool {
	return len(h.preHistory) > 0
}

// RunPostDispatch runs all registered PostDispatch hooks in order.
// Returns response unchanged if no hooks are registered.
func (h *Hooks) RunPostDispatch(ctx context.Context, sessionKey, response string) string {
	for _, fn := range h.postDispatch {
		response = fn(ctx, sessionKey, response)
	}
	return response
}

// RunPreHistory runs all registered PreHistory hooks in order.
// Returns messages unchanged if no hooks are registered.
//
// NOTE: If a hook returns nil or empty when messages was not empty,
// SessionManager logs a warning and falls back to the original messages
// to prevent silent context loss.
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
