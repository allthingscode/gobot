package main

import (
	"context"

	"google.golang.org/genai"
)

// Tool is a function the agent can invoke during a conversation turn.
// Implementations are registered on geminiRunner and exposed to Gemini as
// FunctionDeclarations. When Gemini issues a FunctionCall the runner
// dispatches to the matching Tool.Execute.
type Tool interface {
	// Name returns the function name as declared to Gemini. Must match
	// FunctionDeclaration.Name exactly.
	Name() string

	// Declaration returns the Gemini FunctionDeclaration for this tool,
	// including its description and parameter schema.
	Declaration() *genai.FunctionDeclaration

	// Execute runs the tool with the arguments Gemini supplied.
	// sessionKey is the parent session key for traceability.
	// Returns a plain-text result or an error.
	Execute(ctx context.Context, sessionKey string, args map[string]any) (string, error)
}
