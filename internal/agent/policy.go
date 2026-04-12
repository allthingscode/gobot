package agent

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"

	"gopkg.in/yaml.v3"
)

type PolicyDecision int

const (
	PolicyAllow PolicyDecision = iota
	PolicyDeny
	PolicyRequireHITL
)

func (d PolicyDecision) String() string {
	switch d {
	case PolicyAllow:
		return "allow"
	case PolicyDeny:
		return "deny"
	case PolicyRequireHITL:
		return "require_hitl"
	default:
		return "unknown"
	}
}

type PolicyContext struct {
	ToolName   string
	Args       map[string]any
	UserID     int64
	SessionKey string
}

type Policy interface {
	Evaluate(ctx context.Context, pc PolicyContext) PolicyDecision
}

type AllowAllPolicy struct{}

func (AllowAllPolicy) Evaluate(_ context.Context, _ PolicyContext) PolicyDecision {
	return PolicyAllow
}

type policyRule struct {
	Tool     string `yaml:"tool"`
	Decision string `yaml:"decision"`
}

type policyFile struct {
	Rules []policyRule `yaml:"rules"`
}

type FilePolicy struct {
	rules []policyRule
}

// NewFilePolicy loads a tool execution policy from the specified YAML file.
// If the path is empty or the file does not exist, it returns an AllowAllPolicy.
func NewFilePolicy(path string) (Policy, error) {
	if path == "" {
		slog.Debug("agent/policy: empty path, using allow-all policy")
		return AllowAllPolicy{}, nil
	}

	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			slog.Info("agent/policy: file not found, using allow-all policy", "path", path)
			return AllowAllPolicy{}, nil
		}
		return nil, fmt.Errorf("read policy file: %w", err)
	}

	var pf policyFile
	if err := yaml.Unmarshal(data, &pf); err != nil {
		return nil, fmt.Errorf("parse policy file: %w", err)
	}

	return &FilePolicy{rules: pf.Rules}, nil
}

func (p *FilePolicy) Evaluate(_ context.Context, pc PolicyContext) PolicyDecision {
	for _, rule := range p.rules {
		if matchTool(rule.Tool, pc.ToolName) {
			switch rule.Decision {
			case "deny":
				return PolicyDeny
			case "require_hitl":
				return PolicyRequireHITL
			case "allow":
				return PolicyAllow
			default:
				slog.Warn("agent/policy: unknown decision, treating as allow", "decision", rule.Decision)
				return PolicyAllow
			}
		}
	}
	return PolicyAllow
}

func matchTool(pattern, toolName string) bool {
	if pattern == "*" {
		return true
	}
	if pattern == toolName {
		return true
	}
	return false
}

// ResolvePolicyFilePath determines the absolute path to the tool policy file.
// It prioritizes the explicitly provided configPath; if empty, it defaults
// to tool_policy.yaml within the storageRoot.
func ResolvePolicyFilePath(configPath, storageRoot string) string {
	if configPath != "" {
		return configPath
	}
	return filepath.Join(storageRoot, "tool_policy.yaml")
}

type PolicyHook struct {
	policy Policy
	hitl   *HITLManager
}

// NewPolicyHook creates a new PolicyHook with the given policy and HITL manager.
func NewPolicyHook(policy Policy, hitl *HITLManager) *PolicyHook {
	return &PolicyHook{
		policy: policy,
		hitl:   hitl,
	}
}

func (h *PolicyHook) PreToolHook(ctx context.Context, sessionKey, toolName string, args map[string]any) (string, error) {
	pc := PolicyContext{
		ToolName:   toolName,
		Args:       args,
		SessionKey: sessionKey,
	}

	decision := h.policy.Evaluate(ctx, pc)
	slog.Info("agent/policy: evaluated",
		"tool", toolName,
		"session", sessionKey,
		"decision", decision.String(),
	)

	switch decision {
	case PolicyDeny:
		return "Policy denied: tool is not permitted.", nil
	case PolicyRequireHITL:
		if h.hitl != nil {
			approved, err := h.hitl.RequestApproval(ctx, sessionKey, toolName, args)
			if err != nil {
				return "", err
			}
			if !approved {
				return "Policy denied: approval not granted.", nil
			}
			return "", nil
		}
		return "Policy denied: HITL not configured.", nil
	case PolicyAllow:
		return "", nil
	default:
		return "", nil
	}
}
