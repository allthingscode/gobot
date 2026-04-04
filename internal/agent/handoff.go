package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
)

// HandoffTicket mirrors the schema in .private/HANDOFF_PROTOCOL.md.
type HandoffTicket struct {
	TaskID            string `json:"task_id"`
	SourceSpecialist  string `json:"source_specialist"`
	TargetSpecialist  string `json:"target_specialist"`
	StateFilePath     string `json:"state_file_path"`
	Priority          string `json:"priority"`
	LastOutputSummary string `json:"last_output_summary"`
	AgentPrompt       string `json:"agent_prompt"`
	ResumeCommand     string `json:"resume_command"`
	Timestamp         string `json:"timestamp"`
}

// NewHandoffHook returns a PostDispatchFn that detects handoff.json in the
// storage root and appends the resume command to the agent's response.
//
// If a handoff.json is found, it is read, its resume_command is appended to
// the response, and the file is deleted to prevent duplicate handoffs.
func NewHandoffHook(storageRoot string) PostDispatchFn {
	return func(ctx context.Context, sessionKey string, response string) string {
		handoffPath := filepath.Join(storageRoot, ".private", "session", "handoff.json")

		data, err := os.ReadFile(handoffPath)
		if err != nil {
			if !os.IsNotExist(err) {
				slog.Warn("handoff: failed to read handoff.json", "err", err)
			}
			return response
		}

		var ticket HandoffTicket
		if err := json.Unmarshal(data, &ticket); err != nil {
			slog.Warn("handoff: failed to unmarshal handoff.json", "err", err)
			return response
		}

		// Delete the handoff file so it doesn't trigger again on the next turn
		// if the agent doesn't write a new one.
		if err := os.Remove(handoffPath); err != nil {
			slog.Warn("handoff: failed to delete handoff.json", "err", err)
		}

		slog.Info("handoff: detected handoff.json, appending resume command",
			"session", sessionKey,
			"target", ticket.TargetSpecialist)

		// Format the handoff message
		title := ticket.TargetSpecialist
		if len(title) > 0 {
			title = strings.ToUpper(title[:1]) + title[1:]
		}
		handoffMsg := fmt.Sprintf("\n\n---\n🚀 **HANDOFF DETECTED**\nTarget: %s\nPrompt: %s\n\nCommand:\n`%s`",
			title,
			ticket.AgentPrompt,
			ticket.ResumeCommand)

		return response + handoffMsg
	}
}
