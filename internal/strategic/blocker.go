package strategic

import (
	"fmt"
	"log/slog"

	"google.golang.org/adk/tool"
)

// RoleBlocker returns a BeforeToolCallback that prevents blocked tools from
// executing. Returning a non-nil map skips the actual tool call; the map is
// returned to the agent as the tool result.
//
// blockedTools is the set of tool names to deny. Pass nil to allow all tools.
func RoleBlocker(blockedTools map[string]bool) func(tool.Context, tool.Tool, map[string]any) (map[string]any, error) {
	return func(_ tool.Context, t tool.Tool, _ map[string]any) (map[string]any, error) {
		if blockedTools[t.Name()] {
			slog.Info("strategic: blocked tool call", "tool", t.Name())
			return map[string]any{
				"error": fmt.Sprintf(
					"MANDATE VIOLATION: %q is blocked for this role. Use the spawn tool instead.",
					t.Name(),
				),
			}, nil
		}
		return nil, nil // allow
	}
}
