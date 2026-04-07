package agent

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestHandoffHook(t *testing.T) {
	// Setup a temporary workspace.
	tmpDir, err := os.MkdirTemp("", "gobot-handoff-test")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", tmpDir)
	}
	defer os.RemoveAll(tmpDir)

	sessionDir := filepath.Join(tmpDir, ".private", "session")
	if err := os.MkdirAll(sessionDir, 0755); err != nil {
		t.Fatalf("failed to create session dir: %v", err)
	}

	handoffPath := filepath.Join(sessionDir, "handoff.json")
	ticket := HandoffTicket{
		TargetSpecialist: "reviewer",
		ResumeCommand:    "gemini \"resume review\"",
		AgentPrompt:      "Please review F-123.",
	}
	data, _ := json.Marshal(ticket)
	if err := os.WriteFile(handoffPath, data, 0600); err != nil {
		t.Fatalf("failed to write handoff.json: %v", err)
	}

	// Create and run the hook.
	hook := NewHandoffHook(tmpDir)
	response := "Implementation complete."
	got := hook(context.Background(), "test-session", response)

	// Verify appending.
	if !strings.Contains(got, "🚀 **HANDOFF DETECTED**") {
		t.Error("response missing handoff header")
	}
	if !strings.Contains(got, "gemini \"resume review\"") {
		t.Error("response missing resume command")
	}
	if !strings.Contains(got, "Please review F-123.") {
		t.Error("response missing agent prompt")
	}

	// Verify file was deleted.
	if _, err := os.Stat(handoffPath); !os.IsNotExist(err) {
		t.Error("handoff.json was not deleted after being read")
	}

	// Verify it doesn't run again if file is gone.
	got2 := hook(context.Background(), "test-session", response)
	if got2 != response {
		t.Errorf("expected original response when handoff.json is missing, got: %q", got2)
	}
}
