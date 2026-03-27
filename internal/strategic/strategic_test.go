package strategic_test

import (
	"fmt"
	"testing"

	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/strategic"
)

// ── Mandate (Q1) ─────────────────────────────────────────────────────────────

func TestMandateProvider_ReturnsConfiguredMandate(t *testing.T) {
	cfg := &config.Config{}
	cfg.Strategic.Mandate = "You must follow the strategic mandate."

	provider := strategic.MandateProvider(cfg)
	got, err := provider(nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != cfg.Strategic.Mandate {
		t.Errorf("got %q, want %q", got, cfg.Strategic.Mandate)
	}
}

func TestMandateProvider_EmptyMandate(t *testing.T) {
	cfg := &config.Config{}
	provider := strategic.MandateProvider(cfg)
	got, err := provider(nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "" {
		t.Errorf("expected empty mandate, got %q", got)
	}
}

// ── RoleBlocker (Q2) ──────────────────────────────────────────────────────────

// stubTool implements just enough of tool.Tool for testing the blocker.
type stubTool struct{ name string }

func (s stubTool) Name() string        { return s.name }
func (s stubTool) Description() string { return "" }
func (s stubTool) IsLongRunning() bool { return false }

func TestRoleBlocker_BlocksListedTool(t *testing.T) {
	blocked := map[string]bool{"drive_tool": true}
	cb := strategic.RoleBlocker(blocked)

	result, err := cb(nil, stubTool{"drive_tool"}, nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result == nil {
		t.Fatal("expected non-nil result map (tool should be blocked)")
	}
	if _, hasError := result["error"]; !hasError {
		t.Error("expected 'error' key in blocked result")
	}
}

func TestRoleBlocker_AllowsUnlistedTool(t *testing.T) {
	blocked := map[string]bool{"drive_tool": true}
	cb := strategic.RoleBlocker(blocked)

	result, err := cb(nil, stubTool{"echo_tool"}, nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result != nil {
		t.Errorf("expected nil result (tool should be allowed), got %v", result)
	}
}

func TestRoleBlocker_NilBlocklist(t *testing.T) {
	cb := strategic.RoleBlocker(nil)
	result, err := cb(nil, stubTool{"any_tool"}, nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result != nil {
		t.Errorf("expected nil result for nil blocklist, got %v", result)
	}
}

// ── CLIXMLStripper (Q3) ───────────────────────────────────────────────────────

func TestCLIXMLStripper_StripsPrefix(t *testing.T) {
	cb := strategic.CLIXMLStripper()
	input := map[string]any{"output": "#< CLIXML\nEcho: hello"}

	result, err := cb(nil, stubTool{"echo_tool"}, nil, input, nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result == nil {
		t.Fatal("expected non-nil result after stripping")
	}
	want := "Echo: hello"
	if got, _ := result["output"].(string); got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestCLIXMLStripper_PassthroughCleanOutput(t *testing.T) {
	cb := strategic.CLIXMLStripper()
	input := map[string]any{"output": "normal output"}

	result, err := cb(nil, stubTool{"echo_tool"}, nil, input, nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result != nil {
		t.Errorf("expected nil (no change) for clean output, got %v", result)
	}
}

func TestCLIXMLStripper_CLIXMLOnlyNoNewline(t *testing.T) {
	cb := strategic.CLIXMLStripper()
	input := map[string]any{"output": "#< CLIXML"}

	result, err := cb(nil, stubTool{"echo_tool"}, nil, input, nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result == nil {
		t.Fatal("expected non-nil result")
	}
	if got, _ := result["output"].(string); got != "" {
		t.Errorf("expected empty string after stripping header-only CLIXML, got %q", got)
	}
}

func TestCLIXMLStripper_PropagatesToolError(t *testing.T) {
	cb := strategic.CLIXMLStripper()
	toolErr := fmt.Errorf("tool failed")
	result, err := cb(nil, stubTool{"echo_tool"}, nil, nil, toolErr)
	if err != toolErr {
		t.Errorf("expected tool error to propagate, got %v", err)
	}
	if result != nil {
		t.Errorf("expected nil result on error, got %v", result)
	}
}
