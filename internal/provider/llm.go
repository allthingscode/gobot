package provider

import (
	"context"

	agentctx "github.com/allthingscode/gobot/internal/context"
)

// Provider defines the interface for an LLM provider (Gemini, Anthropic, OpenAI, etc).
type Provider interface {
	// Name returns the provider identifier (e.g. "gemini", "anthropic").
	Name() string

	// Chat executes a single-turn LLM call.
	Chat(ctx context.Context, req ChatRequest) (*ChatResponse, error)

	// Models returns information about models supported by this provider.
	Models() []ModelInfo
}

// ChatRequest represents the payload sent to a Provider.
type ChatRequest struct {
	Model             string
	Messages          []agentctx.StrategicMessage
	SystemInstruction string
	Tools             []ToolDeclaration
	MaxTokens         int
	Temperature       float32
}

// ChatResponse represents the final response from a Provider.
type ChatResponse struct {
	Message agentctx.StrategicMessage
	Usage   TokenUsage
}

// ToolDeclaration matches the structure expected by most LLMs for function definitions.
// It uses a generic Parameters field (JSON Schema) to remain provider-agnostic.
type ToolDeclaration struct {
	Name          string
	Description   string
	Parameters    map[string]any // JSON Schema (type: object)
	SideEffecting bool           // true = tool modifies external state; enable idempotency protection
}

// TokenUsage tracks the cost of a request.
type TokenUsage struct {
	PromptTokens     int
	CompletionTokens int
	TotalTokens      int
}

// ModelInfo describes a model's capabilities and limits.
type ModelInfo struct {
	ID               string
	ContextWindow    int
	MaxOutputTokens  int
	SupportsToolUse  bool
	SupportsImage    bool
	SupportsThinking bool
}
