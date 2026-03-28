package agent

import (
	"context"

	agentctx "github.com/allthingscode/gobot/internal/context"
)

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
}

// RegisterPreHistory appends fn to the PreHistory chain.
func (h *Hooks) RegisterPreHistory(fn PreHistoryFn) {
	h.preHistory = append(h.preHistory, fn)
}

// RegisterPrePrompt appends fn to the PrePrompt chain.
func (h *Hooks) RegisterPrePrompt(fn PrePromptFn) {
	h.prePrompt = append(h.prePrompt, fn)
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
