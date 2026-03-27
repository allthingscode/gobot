package strategic

import (
	"log/slog"
	"strings"

	"google.golang.org/adk/tool"
)

// CLIXMLStripper returns an AfterToolCallback that removes the "#< CLIXML\n"
// header that PowerShell error streams sometimes prefix onto tool output.
//
// Returning a non-nil map replaces the tool result before the agent sees it.
func CLIXMLStripper() func(tool.Context, tool.Tool, map[string]any, map[string]any, error) (map[string]any, error) {
	return func(_ tool.Context, t tool.Tool, _ map[string]any, result map[string]any, err error) (map[string]any, error) {
		if err != nil {
			return nil, err
		}
		output, ok := result["output"].(string)
		if !ok {
			return nil, nil
		}
		if !strings.HasPrefix(output, "#< CLIXML") {
			return nil, nil
		}
		idx := strings.Index(output, "\n")
		if idx >= 0 {
			output = strings.TrimSpace(output[idx+1:])
		} else {
			output = ""
		}
		slog.Info("strategic: CLIXML stripped", "tool", t.Name())
		return map[string]any{"output": output}, nil
	}
}
