//nolint:testpackage // requires access to internal app types for integration testing
package app

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
)

type hitlMockAPI struct {
	bot.API
}

func TestHITLInitialization(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	cfg.Tools.HighRisk = []string{"danger_tool"}
	cfg.Channels.Telegram.AllowFrom = []string{"12345"}

	runner := &AgentRunner{}
	mgr := &agent.SessionManager{}
	api := &hitlMockAPI{}

	_, hitl := SetupHooks(cfg, runner, mgr, api, nil)

	// Verify that HITL manager is initialized with HighRisk tools, NOT chat IDs
	ctx := context.Background()

	// This should fail-closed because it's a high-risk tool and session is not telegram
	// BUT if it's initialized with chat IDs, it won't even try to request approval!
	_, err := hitl.PreToolHook(ctx, "cli:user", "danger_tool", nil)

	if err == nil {
		t.Error("expected error (fail-closed) for high-risk tool on CLI session, but got nil")
	}
}

func TestHITLPolicyFailClosed(t *testing.T) {
	t.Parallel()
	tempDir, err := os.MkdirTemp("", "hitl-policy-test-*")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tempDir)

	policyPath := filepath.Join(tempDir, "policy.yaml")
	policyContent := `
rules:
  - tool: "secret_tool"
    decision: require_hitl
`
	if err := os.WriteFile(policyPath, []byte(policyContent), 0o600); err != nil {
		t.Fatalf("failed to write policy file: %v", err)
	}

	cfg := &config.Config{}
	cfg.Strategic.PolicyFilePath = policyPath

	runner := &AgentRunner{}
	mgr := &agent.SessionManager{}
	api := &hitlMockAPI{}

	hooks, _ := SetupHooks(cfg, runner, mgr, api, nil)

	// Verify that policy-required HITL fails closed for non-Telegram sessions
	ctx := context.Background()
	_, err = hooks.RunPreTool(ctx, "cli:user", "secret_tool", nil)

	if err == nil {
		t.Error("expected error (fail-closed) for policy-required HITL on CLI session, but got nil")
	} else if !strings.Contains(err.Error(), "unsupported for HITL") {
		t.Errorf("expected error containing 'unsupported for HITL', got: %v", err)
	}
}

func TestHITLCronAutoApprove(t *testing.T) {
	t.Parallel()
	tempDir, err := os.MkdirTemp("", "hitl-cron-test-*")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tempDir)

	policyPath := filepath.Join(tempDir, "policy.yaml")
	policyContent := `
rules:
  - tool: "secret_tool"
    decision: require_hitl
`
	if err := os.WriteFile(policyPath, []byte(policyContent), 0o600); err != nil {
		t.Fatalf("failed to write policy file: %v", err)
	}

	cfg := &config.Config{}
	cfg.Strategic.PolicyFilePath = policyPath

	runner := &AgentRunner{}
	mgr := &agent.SessionManager{}
	api := &hitlMockAPI{}

	hooks, _ := SetupHooks(cfg, runner, mgr, api, nil)

	// Verify that cron sessions are auto-approved even if policy requires HITL
	ctx := context.Background()
	got, err := hooks.RunPreTool(ctx, "cron:test_job", "secret_tool", nil)

	if err != nil {
		t.Errorf("expected no error for cron auto-approval, got: %v", err)
	}
	if got != "" {
		t.Errorf("expected empty string (continue to execution), got: %q", got)
	}
}
