//nolint:testpackage // requires access to internal app types for integration testing
package app

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/provider"
)

type hitlMockAPI struct {
	bot.API
}

const hitlDeadlineAction = "deadline"

type hitlLoopAPI struct {
	bot.API
	requests chan [][]bot.Button
}

func (a *hitlLoopAPI) Send(_ context.Context, _ bot.OutboundMessage) error { return nil }
func (a *hitlLoopAPI) SendWithButtons(ctx context.Context, _ bot.OutboundMessage, buttons [][]bot.Button) error {
	select {
	case a.requests <- buttons:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

type hitlLoopTool struct {
	name  string
	write bool
	calls atomic.Int32
}

func (tool *hitlLoopTool) Name() string { return tool.name }
func (tool *hitlLoopTool) Declaration() provider.ToolDeclaration {
	return provider.ToolDeclaration{Name: tool.name, SideEffecting: tool.write}
}
func (tool *hitlLoopTool) Execute(_ context.Context, _, _ string, _ map[string]any) (string, error) {
	tool.calls.Add(1)
	return "executed", nil
}

type hitlLoopCase struct {
	name, tool, session, policy, action      string
	enabled, write, highRisk, prompt, denied bool
}

func newHITLLoop(t *testing.T, tc hitlLoopCase) (*AgentRunner, *agent.HITLManager, *hitlLoopAPI, *hitlLoopTool) {
	t.Helper()
	cfg := &config.Config{}
	cfg.Runtime.StorageRoot = t.TempDir()
	cfg.Channels.Telegram.HITL = tc.enabled
	if tc.highRisk {
		cfg.Tools.HighRisk = []string{tc.tool}
	}
	if tc.policy != "" {
		cfg.Runtime.PolicyFilePath = filepath.Join(cfg.StorageRoot(), "policy.yaml")
		content := "rules: [{tool: '" + tc.tool + "', decision: " + tc.policy + "}]"
		if err := os.WriteFile(cfg.Runtime.PolicyFilePath, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	prov := &MockProvider{Responses: []*provider.ChatResponse{
		{Message: agentctx.StrategicMessage{Role: agentctx.RoleAssistant, ToolCalls: []agentctx.ToolCall{{Name: tc.tool}}}},
		{Message: agentctx.StrategicMessage{Role: agentctx.RoleAssistant, Content: &agentctx.MessageContent{Str: strPtr("done")}}},
	}}
	runner := NewAgentRunner(prov, "test", "", cfg)
	api := &hitlLoopAPI{requests: make(chan [][]bot.Button, 4)}
	_, hitl, err := SetupHooks(cfg, runner, &agent.SessionManager{}, api, nil)
	if err != nil {
		t.Fatal(err)
	}
	tool := &hitlLoopTool{name: tc.tool, write: tc.write}
	// Registration after setup must be seen by the channel hook.
	runner.SetTools([]Tool{tool})
	return runner, hitl, api, tool
}

func runHITLLoopCase(t *testing.T, tc hitlLoopCase) {
	t.Helper()
	runner, hitl, api, tool := newHITLLoop(t, tc)
	ctx, cancel := hitlLoopContext(tc.action)
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, _, err := runner.Run(ctx, tc.session, "", nil)
		done <- err
	}()
	if tc.prompt {
		select {
		case buttons := <-api.requests:
			if tool.calls.Load() != 0 {
				t.Fatal("executor ran before approval")
			}
			completeHITLLoopRequest(t, ctx, cancel, hitl, tc.action, buttons)
		case err := <-done:
			t.Fatalf("runner ended before requesting approval: %v", err)
		case <-ctx.Done():
			t.Fatal("no approval request")
		}
	}
	select {
	case err := <-done:
		assertHITLLoopResult(t, tc, err, tool.calls.Load())
	case <-time.After(5 * time.Second):
		t.Fatal("runner did not finish")
	}
	select {
	case <-api.requests:
		t.Fatal("unexpected approval prompt")
	default:
	}
}

func hitlLoopContext(action string) (context.Context, context.CancelFunc) {
	timeout := 5 * time.Second
	if action == hitlDeadlineAction {
		timeout = time.Second
	}
	return context.WithTimeout(context.Background(), timeout)
}

func assertHITLLoopResult(t *testing.T, tc hitlLoopCase, err error, calls int32) {
	t.Helper()
	if (err != nil) != tc.denied {
		t.Fatalf("runner error = %v, denied = %v", err, tc.denied)
	}
	if tc.action == "cancel" && !errors.Is(err, context.Canceled) {
		t.Fatalf("lost cancellation cause: %v", err)
	}
	if tc.action == hitlDeadlineAction && !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("lost deadline cause: %v", err)
	}
	want := int32(1)
	if tc.denied {
		want = 0
	}
	if calls != want {
		t.Fatalf("executor calls = %d, want %d", calls, want)
	}
}

func completeHITLLoopRequest(t *testing.T, ctx context.Context, cancel context.CancelFunc, hitl *agent.HITLManager, action string, buttons [][]bot.Button) {
	t.Helper()
	if action == "cancel" {
		cancel()
		return
	}
	if action == hitlDeadlineAction {
		return
	}
	index := 0
	if action == "reject" {
		index = 1
	}
	if err := hitl.HandleCallback(ctx, bot.InboundCallback{ChatID: 123, Data: buttons[0][index].Data}); err != nil {
		t.Fatal(err)
	}
}

func TestHITLRunnerChannelWrites(t *testing.T) {
	t.Parallel()
	for _, tool := range []string{"shell_exec", "send_email", "google_calendar_create_event", "custom_write"} {
		for _, action := range []string{"approve", "reject", "cancel", hitlDeadlineAction} {
			t.Run(tool+"/"+action, func(t *testing.T) {
				t.Parallel()
				runHITLLoopCase(t, hitlLoopCase{tool: tool, session: "telegram:123:456", action: action,
					enabled: true, write: true, prompt: true, denied: action != "approve"})
			})
		}
	}
}

func TestHITLRunnerIndependentControls(t *testing.T) {
	t.Parallel()
	for _, enabled := range []bool{false, true} {
		for _, tc := range []hitlLoopCase{
			{name: "read", session: "telegram:123"},
			{name: "write switch", session: "telegram:123", write: true, prompt: enabled},
			{name: "unsupported channel write", session: "cli:user", write: true},
			{name: "high risk", session: "telegram:123", highRisk: true, prompt: true},
			{name: "policy approval", session: "telegram:123", policy: "require_hitl", prompt: true},
			{name: "policy deny", session: "telegram:123", policy: "deny", write: true, highRisk: true, denied: true},
			{name: "policy allow channel", session: "telegram:123", policy: "allow", write: true, prompt: enabled},
			{name: "policy allow high risk", session: "telegram:123", policy: "allow", highRisk: true, prompt: true},
			{name: "unsupported high risk", session: "cli:user", highRisk: true, denied: true},
			{name: "unsupported policy approval", session: "cli:user", policy: "require_hitl", denied: true},
			{name: "cron high risk", session: "cron:job", write: true, highRisk: true},
			{name: "cron policy approval", session: "cron:job", write: true, policy: "require_hitl"},
			{name: "cron deny", session: "cron:job", write: true, highRisk: true, policy: "deny", denied: true},
		} {
			t.Run(fmt.Sprintf("%s/enabled=%t", tc.name, enabled), func(t *testing.T) {
				t.Parallel()
				tc.tool, tc.enabled, tc.action = "test_tool", enabled, "approve"
				runHITLLoopCase(t, tc)
			})
		}
	}
}

func TestHITLRunnerRegistryIsolation(t *testing.T) {
	t.Parallel()
	tc := hitlLoopCase{tool: "custom_write", enabled: true, write: true}
	runner, _, _, _ := newHITLLoop(t, tc)
	other, _, _, _ := newHITLLoop(t, tc)
	// Replacing one registry with a read must not change another runner's scope.
	runner.SetTools([]Tool{&hitlLoopTool{name: tc.tool}})
	_, err := runner.Hooks.RunPreTool(context.Background(), "telegram:123", tc.tool, nil)
	if err != nil {
		t.Fatalf("replaced read tool requested approval: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := other.Hooks.RunPreTool(ctx, "telegram:123", tc.tool, nil); err == nil {
		t.Fatal("another runner's write lost approval protection")
	}
}

func TestHITLRunnerUnavailableAPI(t *testing.T) {
	t.Parallel()
	runner, _, _, tool := newHITLLoop(t, hitlLoopCase{tool: "custom_write", enabled: true, write: true})
	if _, _, err := SetupHooks(runner.Cfg, runner, &agent.SessionManager{}, nil, nil); err != nil {
		t.Fatal(err)
	}
	_, _, err := runner.Run(context.Background(), "telegram:123", "", nil)
	if err == nil || !strings.Contains(err.Error(), "available Telegram API") || tool.calls.Load() != 0 {
		t.Fatalf("unavailable API must fail before execution: err=%v calls=%d", err, tool.calls.Load())
	}
}

func TestHITLInitialization(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	cfg.Tools.HighRisk = []string{"danger_tool"}
	cfg.Channels.Telegram.AllowFrom = []string{"12345"}

	runner := &AgentRunner{}
	mgr := &agent.SessionManager{}
	api := &hitlMockAPI{}

	_, hitl, setupErr := SetupHooks(cfg, runner, mgr, api, nil)
	if setupErr != nil {
		t.Fatalf("SetupHooks: %v", setupErr)
	}

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
	cfg.Runtime.PolicyFilePath = policyPath

	runner := &AgentRunner{}
	mgr := &agent.SessionManager{}
	api := &hitlMockAPI{}

	hooks, _, setupErr := SetupHooks(cfg, runner, mgr, api, nil)
	if setupErr != nil {
		t.Fatalf("SetupHooks: %v", setupErr)
	}

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
	cfg.Runtime.PolicyFilePath = policyPath

	runner := &AgentRunner{}
	mgr := &agent.SessionManager{}
	api := &hitlMockAPI{}

	hooks, _, setupErr := SetupHooks(cfg, runner, mgr, api, nil)
	if setupErr != nil {
		t.Fatalf("SetupHooks: %v", setupErr)
	}

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
