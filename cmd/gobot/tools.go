package main

import (
	"context"
	"github.com/allthingscode/gobot/internal/provider"
)

// Tool is a function the agent can invoke during a conversation turn.
type Tool interface {
	// Name returns the function name.
	Name() string

	// Declaration returns the provider-agnostic tool declaration.
	Declaration() provider.ToolDeclaration

	// Execute runs the tool with the supplied arguments.
	Execute(ctx context.Context, sessionKey string, args map[string]any) (string, error)
}
