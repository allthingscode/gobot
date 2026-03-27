// Package strategic provides ADK Go hooks that enforce the Strategic Edition mandates:
//
//   - Mandate injection via GlobalInstructionProvider (Q1)
//   - Role-based tool blocking via BeforeToolCallback (Q2)
//   - CLIXML output hardening via AfterToolCallback (Q3)
package strategic

import (
	"github.com/allthingscode/gobot/internal/config"
	"google.golang.org/adk/agent"
)

// MandateProvider returns a GlobalInstructionProvider that prepends the
// configured mandate text to every agent's system prompt.
//
// The mandate is loaded once from cfg at construction time; it does not
// reload dynamically. Callers that need live reload should re-build the
// provider after a config reload.
func MandateProvider(cfg *config.Config) func(agent.ReadonlyContext) (string, error) {
	mandate := cfg.Strategic.Mandate
	return func(_ agent.ReadonlyContext) (string, error) {
		return mandate, nil
	}
}
