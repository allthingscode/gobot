package agent

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestPolicyDecision_String(t *testing.T) {
	t.Parallel()
	tests := []struct {
		decision PolicyDecision
		want     string
	}{
		{PolicyAllow, "allow"},
		{PolicyDeny, "deny"},
		{PolicyRequireHITL, "require_hitl"},
		{PolicyDecision(99), "unknown"},
	}
	for _, tt := range tests {
		if got := tt.decision.String(); got != tt.want {
			t.Errorf("PolicyDecision.String() = %q, want %q", got, tt.want)
		}
	}
}

func TestAllowAllPolicy_Evaluate(t *testing.T) {
	t.Parallel()
	p := AllowAllPolicy{}
	ctx := context.Background()
	pc := PolicyContext{ToolName: "any_tool", Args: map[string]any{"arg": "val"}}

	got := p.Evaluate(ctx, pc)
	if got != PolicyAllow {
		t.Errorf("AllowAllPolicy.Evaluate() = %v, want %v", got, PolicyAllow)
	}
}

func TestNewFilePolicy_EmptyPath(t *testing.T) {
	t.Parallel()
	p, err := NewFilePolicy("")
	if err != nil {
		t.Fatalf("NewFilePolicy(%q) error = %v", "", err)
	}
	if _, ok := p.(AllowAllPolicy); !ok {
		t.Error("expected AllowAllPolicy for empty path")
	}
}

func TestNewFilePolicy_FileNotFound(t *testing.T) {
	t.Parallel()
	p, err := NewFilePolicy("/nonexistent/path/to/policy.yaml")
	if err != nil {
		t.Fatalf("NewFilePolicy(%q) error = %v", "/nonexistent/path/to/policy.yaml", err)
	}
	if _, ok := p.(AllowAllPolicy); !ok {
		t.Error("expected AllowAllPolicy for nonexistent file")
	}
}

func TestNewFilePolicy_ValidFile(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	policyPath := filepath.Join(tmpDir, "tool_policy.yaml")
	policyContent := `rules:
  - tool: "shell.run"
    decision: deny
  - tool: "gmail.send"
    decision: require_hitl
  - tool: "*"
    decision: allow
`
	if err := os.WriteFile(policyPath, []byte(policyContent), 0o600); err != nil {
		t.Fatalf("failed to write test policy: %v", err)
	}

	p, err := NewFilePolicy(policyPath)
	if err != nil {
		t.Fatalf("NewFilePolicy(%q) error = %v", policyPath, err)
	}
	fp, ok := p.(*FilePolicy)
	if !ok {
		t.Fatalf("expected *FilePolicy, got %T", p)
	}
	if len(fp.rules) != 3 {
		t.Errorf("expected 3 rules, got %d", len(fp.rules))
	}
}

func TestNewFilePolicy_InvalidYAML(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	policyPath := filepath.Join(tmpDir, "tool_policy.yaml")
	if err := os.WriteFile(policyPath, []byte("invalid: [yaml: content"), 0o600); err != nil {
		t.Fatalf("failed to write test policy: %v", err)
	}

	_, err := NewFilePolicy(policyPath)
	if err == nil {
		t.Error("expected error for invalid YAML")
	}
}

func TestFilePolicy_Evaluate_Deny(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	policyPath := filepath.Join(tmpDir, "tool_policy.yaml")
	policyContent := `rules:
  - tool: "shell.run"
    decision: deny
`
	if err := os.WriteFile(policyPath, []byte(policyContent), 0o600); err != nil {
		t.Fatalf("failed to write test policy: %v", err)
	}

	p, err := NewFilePolicy(policyPath)
	if err != nil {
		t.Fatalf("NewFilePolicy error = %v", err)
	}

	ctx := context.Background()
	pc := PolicyContext{ToolName: "shell.run"}
	got := p.Evaluate(ctx, pc)
	if got != PolicyDeny {
		t.Errorf("FilePolicy.Evaluate() = %v, want %v", got, PolicyDeny)
	}
}

func TestFilePolicy_Evaluate_RequireHITL(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	policyPath := filepath.Join(tmpDir, "tool_policy.yaml")
	policyContent := `rules:
  - tool: "gmail.send"
    decision: require_hitl
`
	if err := os.WriteFile(policyPath, []byte(policyContent), 0o600); err != nil {
		t.Fatalf("failed to write test policy: %v", err)
	}

	p, err := NewFilePolicy(policyPath)
	if err != nil {
		t.Fatalf("NewFilePolicy error = %v", err)
	}

	ctx := context.Background()
	pc := PolicyContext{ToolName: "gmail.send"}
	got := p.Evaluate(ctx, pc)
	if got != PolicyRequireHITL {
		t.Errorf("FilePolicy.Evaluate() = %v, want %v", got, PolicyRequireHITL)
	}
}

func TestFilePolicy_Evaluate_Allow(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	policyPath := filepath.Join(tmpDir, "tool_policy.yaml")
	policyContent := `rules:
  - tool: "*"
    decision: allow
`
	if err := os.WriteFile(policyPath, []byte(policyContent), 0o600); err != nil {
		t.Fatalf("failed to write test policy: %v", err)
	}

	p, err := NewFilePolicy(policyPath)
	if err != nil {
		t.Fatalf("NewFilePolicy error = %v", err)
	}

	ctx := context.Background()
	pc := PolicyContext{ToolName: "some_random_tool"}
	got := p.Evaluate(ctx, pc)
	if got != PolicyAllow {
		t.Errorf("FilePolicy.Evaluate() = %v, want %v", got, PolicyAllow)
	}
}

func TestFilePolicy_Evaluate_WildcardDefault(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	policyPath := filepath.Join(tmpDir, "tool_policy.yaml")
	policyContent := `rules:
  - tool: "shell.run"
    decision: deny
  - tool: "*"
    decision: allow
`
	if err := os.WriteFile(policyPath, []byte(policyContent), 0o600); err != nil {
		t.Fatalf("failed to write test policy: %v", err)
	}

	p, err := NewFilePolicy(policyPath)
	if err != nil {
		t.Fatalf("NewFilePolicy error = %v", err)
	}

	ctx := context.Background()
	pc := PolicyContext{ToolName: "unknown_tool"}
	got := p.Evaluate(ctx, pc)
	if got != PolicyAllow {
		t.Errorf("FilePolicy.Evaluate() = %v, want %v", got, PolicyAllow)
	}
}

func TestFilePolicy_Evaluate_FirstMatchWins(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	policyPath := filepath.Join(tmpDir, "tool_policy.yaml")
	policyContent := `rules:
  - tool: "shell.run"
    decision: deny
  - tool: "shell.run"
    decision: allow
`
	if err := os.WriteFile(policyPath, []byte(policyContent), 0o600); err != nil {
		t.Fatalf("failed to write test policy: %v", err)
	}

	p, err := NewFilePolicy(policyPath)
	if err != nil {
		t.Fatalf("NewFilePolicy error = %v", err)
	}

	ctx := context.Background()
	pc := PolicyContext{ToolName: "shell.run"}
	got := p.Evaluate(ctx, pc)
	if got != PolicyDeny {
		t.Errorf("FilePolicy.Evaluate() = %v, want %v (first match should win)", got, PolicyDeny)
	}
}

func TestFilePolicy_Evaluate_UnknownDecision(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	policyPath := filepath.Join(tmpDir, "tool_policy.yaml")
	policyContent := `rules:
  - tool: "some_tool"
    decision: invalid_decision
`
	if err := os.WriteFile(policyPath, []byte(policyContent), 0o600); err != nil {
		t.Fatalf("failed to write test policy: %v", err)
	}

	p, err := NewFilePolicy(policyPath)
	if err != nil {
		t.Fatalf("NewFilePolicy error = %v", err)
	}

	ctx := context.Background()
	pc := PolicyContext{ToolName: "some_tool"}
	got := p.Evaluate(ctx, pc)
	if got != PolicyAllow {
		t.Errorf("FilePolicy.Evaluate() = %v, want %v (unknown decision should default to allow)", got, PolicyAllow)
	}
}

func TestFilePolicy_Evaluate_NoRules(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	policyPath := filepath.Join(tmpDir, "tool_policy.yaml")
	policyContent := `rules: []
`
	if err := os.WriteFile(policyPath, []byte(policyContent), 0o600); err != nil {
		t.Fatalf("failed to write test policy: %v", err)
	}

	p, err := NewFilePolicy(policyPath)
	if err != nil {
		t.Fatalf("NewFilePolicy error = %v", err)
	}

	ctx := context.Background()
	pc := PolicyContext{ToolName: "any_tool"}
	got := p.Evaluate(ctx, pc)
	if got != PolicyAllow {
		t.Errorf("FilePolicy.Evaluate() with empty rules = %v, want %v", got, PolicyAllow)
	}
}

func TestMatchTool(t *testing.T) {
	t.Parallel()
	tests := []struct {
		pattern  string
		toolName string
		want     bool
	}{
		{"*", "any_tool", true},
		{"shell.run", "shell.run", true},
		{"shell.run", "gmail.send", false},
		{"shell.*", "shell.run", false},
	}
	for _, tt := range tests {
		if got := matchTool(tt.pattern, tt.toolName); got != tt.want {
			t.Errorf("matchTool(%q, %q) = %v, want %v", tt.pattern, tt.toolName, got, tt.want)
		}
	}
}

func TestResolvePolicyFilePath(t *testing.T) {
	t.Parallel()
	tests := []struct {
		configPath  string
		storageRoot string
		want        string
	}{
		{"/custom/path.yaml", "/storage", "/custom/path.yaml"},
		{"", "C:\\storage", "C:\\storage\\tool_policy.yaml"},
	}
	for _, tt := range tests {
		if got := ResolvePolicyFilePath(tt.configPath, tt.storageRoot); got != tt.want {
			t.Errorf("ResolvePolicyFilePath(%q, %q) = %q, want %q", tt.configPath, tt.storageRoot, got, tt.want)
		}
	}
}

func TestPolicyHook_PreToolHook_Deny(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	policyPath := filepath.Join(tmpDir, "tool_policy.yaml")
	policyContent := `rules:
  - tool: "denied_tool"
    decision: deny
`
	if err := os.WriteFile(policyPath, []byte(policyContent), 0o600); err != nil {
		t.Fatalf("failed to write test policy: %v", err)
	}

	policy, err := NewFilePolicy(policyPath)
	if err != nil {
		t.Fatalf("NewFilePolicy error = %v", err)
	}

	hook := NewPolicyHook(policy, nil)

	ctx := context.Background()
	result, err := hook.PreToolHook(ctx, "session", "denied_tool", nil)
	if err != nil {
		t.Fatalf("PreToolHook() error = %v", err)
	}
	if result == "" {
		t.Error("expected non-empty result for denied tool")
	}
	if result != "Policy denied: tool is not permitted." {
		t.Errorf("unexpected result: %q", result)
	}
}

func TestPolicyHook_PreToolHook_Allow(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	policyPath := filepath.Join(tmpDir, "tool_policy.yaml")
	policyContent := `rules:
  - tool: "*"
    decision: allow
`
	if err := os.WriteFile(policyPath, []byte(policyContent), 0o600); err != nil {
		t.Fatalf("failed to write test policy: %v", err)
	}

	policy, err := NewFilePolicy(policyPath)
	if err != nil {
		t.Fatalf("NewFilePolicy error = %v", err)
	}

	hook := NewPolicyHook(policy, nil)

	ctx := context.Background()
	result, err := hook.PreToolHook(ctx, "session", "any_tool", nil)
	if err != nil {
		t.Fatalf("PreToolHook() error = %v", err)
	}
	if result != "" {
		t.Errorf("expected empty result for allowed tool, got: %q", result)
	}
}

func TestPolicyHook_PreToolHook_RequireHITL_NoHITLManager(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	policyPath := filepath.Join(tmpDir, "tool_policy.yaml")
	policyContent := `rules:
  - tool: "gmail.send"
    decision: require_hitl
`
	if err := os.WriteFile(policyPath, []byte(policyContent), 0o600); err != nil {
		t.Fatalf("failed to write test policy: %v", err)
	}

	policy, err := NewFilePolicy(policyPath)
	if err != nil {
		t.Fatalf("NewFilePolicy error = %v", err)
	}

	hook := NewPolicyHook(policy, nil)

	ctx := context.Background()
	result, err := hook.PreToolHook(ctx, "session", "gmail.send", nil)
	if err != nil {
		t.Fatalf("PreToolHook() error = %v", err)
	}
	if result != "Policy denied: HITL not configured." {
		t.Errorf("unexpected result: %q", result)
	}
}
