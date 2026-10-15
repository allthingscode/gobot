package app

import (
	"fmt"
	"log/slog"
	"strings"
	"unicode/utf8"

	agentctx "github.com/allthingscode/gobot/internal/context"
)

// ExtractText joins all non-empty text parts from a StrategicMessage.
func ExtractText(msg agentctx.StrategicMessage) string {
	if msg.Content == nil {
		return ""
	}
	if msg.Content.Str != nil {
		return *msg.Content.Str
	}
	var sb strings.Builder
	for _, item := range msg.Content.Items {
		if item.Text != nil {
			sb.WriteString(item.Text.Text)
		}
	}
	return sb.String()
}

// LastUserText returns the content of the most recent user message in the history.
func LastUserText(messages []agentctx.StrategicMessage) string {
	for i := len(messages) - 1; i >= 0; i-- {
		if messages[i].Role == agentctx.RoleUser && messages[i].Content != nil && messages[i].Content.Str != nil {
			return *messages[i].Content.Str
		}
	}
	return ""
}

// BuildCorrectionMessage formats a critic report into a prompt for the agent to revise its response.
func BuildCorrectionMessage(report map[string]any) string {
	feedback, _ := report["feedback"].(string)
	corrections, _ := report["required_corrections"].([]any)

	var sb strings.Builder
	sb.WriteString("The previous response did not fully satisfy the task requirements.\n")
	if feedback != "" {
		sb.WriteString("Critic feedback: ")
		sb.WriteString(feedback)
		sb.WriteString("\n")
	}
	if len(corrections) > 0 {
		sb.WriteString("Required corrections:\n")
		for i, c := range corrections {
			if s, ok := c.(string); ok {
				fmt.Fprintf(&sb, "%d. %s\n", i+1, s)
			}
		}
	}
	sb.WriteString("Please revise your response to address the above.")
	return sb.String()
}

// TruncateToolResult shortens a tool result string to maxBytes if it exceeds the limit.
func TruncateToolResult(result string, maxBytes int) string {
	if maxBytes <= 0 || len(result) <= maxBytes {
		return result
	}
	slog.Info("runner: tool result truncated", "max_bytes", maxBytes, "original_size", len(result))
	idx := maxBytes
	for idx > 0 && !utf8.RuneStart(result[idx]) {
		idx--
	}
	const truncationNotice = "\n\n[... truncated: result exceeded %d bytes ...]"
	return result[:idx] + fmt.Sprintf(truncationNotice, maxBytes)
}
