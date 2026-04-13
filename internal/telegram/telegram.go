// Package telegram provides pure logic for Telegram bot integration.
package telegram

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// Regex for .gobot/media or .gobot\media (case-insensitive).
var mediaPathRegex = regexp.MustCompile(`(?i)\.gobot[\\/]media`)

// GetMediaPath calculates the strategic redirection path for Telegram media.
// If originalPath does not contain ".gobot/media" or ".gobot\media" (case-insensitive),
// it is returned unchanged. Otherwise, the filename is extracted and joined with
// {baseWorkspace}/media/{filename}.
// If baseWorkspace is empty, it defaults to the user's home directory + "/.gobot/workspace".
func GetMediaPath(baseWorkspace, originalPath string) string {
	if originalPath == "" {
		return originalPath
	}

	if !mediaPathRegex.MatchString(originalPath) {
		return originalPath
	}

	workspace := baseWorkspace
	if workspace == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			// Fallback if home directory can't be resolved
			workspace = filepath.Join(".gobot", "workspace")
		} else {
			workspace = filepath.Join(home, ".gobot", "workspace")
		}
	}

	// Always normalize backslashes to forward slashes before calling Base
	// to ensure cross-platform behavior even on non-Windows host OS.
	normalized := strings.ReplaceAll(originalPath, "\\", "/")
	filename := filepath.Base(normalized)
	return filepath.Join(workspace, "media", filename)
}

// DetectThreadMetadata returns thread metadata if messageThreadID is non-zero.
// The returned map contains "message_thread_id" (int64) and
// "session_key_override" (string formatted as "telegram:{chatID}:{messageThreadID}").
// Returns nil if messageThreadID is zero.
func DetectThreadMetadata(messageThreadID, chatID int64) map[string]any {
	if messageThreadID == 0 {
		return nil
	}

	return map[string]any{
		"message_thread_id":    messageThreadID,
		"session_key_override": fmt.Sprintf("telegram:%d:%d", chatID, messageThreadID),
	}
}
