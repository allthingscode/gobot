package agent

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

const (
	policyAllowValue = "allow"
	policyDenyValue  = "deny"
	policyHITLValue  = "require_hitl"
	yamlStringTag    = "!!str"
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
		return policyAllowValue
	case PolicyDeny:
		return policyDenyValue
	case PolicyRequireHITL:
		return policyHITLValue
	default:
		return "unknown" //nolint:goconst // default sentinel value in switch
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
// Only an empty path returns an AllowAllPolicy without reading a file.
func NewFilePolicy(path string) (Policy, error) {
	if path == "" {
		slog.Debug("agent/policy: empty path, using allow-all policy")
		return AllowAllPolicy{}, nil
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read policy file %q: %w", path, err)
	}

	if err := validatePolicyDocument(data); err != nil {
		return nil, fmt.Errorf("validate policy file %q: %w", path, err)
	}
	var pf policyFile
	decoder := yaml.NewDecoder(bytes.NewReader(data))
	decoder.KnownFields(true)
	if err := decoder.Decode(&pf); err != nil {
		return nil, fmt.Errorf("decode policy file %q: %w", path, err)
	}

	return &FilePolicy{rules: pf.Rules}, nil
}

// Validate nodes before typed decoding so YAML scalar coercions cannot turn
// malformed fields into usable rules. All rules are checked, even unreachable ones.
func validatePolicyDocument(data []byte) error {
	decoder := yaml.NewDecoder(bytes.NewReader(data))
	var doc yaml.Node
	if err := decoder.Decode(&doc); err != nil {
		return fmt.Errorf("expected policy document: %w", err)
	}
	var extra yaml.Node
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		return fmt.Errorf("expected exactly one YAML document")
	}
	if len(doc.Content) != 1 {
		return fmt.Errorf("expected mapping root with rules")
	}
	root := doc.Content[0]
	if !isPolicyRoot(root) {
		return fmt.Errorf("root must contain only rules")
	}
	rules := root.Content[1]
	if rules.Kind != yaml.SequenceNode {
		return fmt.Errorf("rules must be a sequence")
	}
	for i, rule := range rules.Content {
		if err := validatePolicyRule(rule); err != nil {
			return fmt.Errorf("rules[%d]: %w", i, err)
		}
	}
	return nil
}

func isPolicyRoot(root *yaml.Node) bool {
	return root.Kind == yaml.MappingNode && len(root.Content) == 2 && root.Content[0].Tag == yamlStringTag && root.Content[0].Value == "rules"
}

func validatePolicyRule(rule *yaml.Node) error {
	if rule.Kind != yaml.MappingNode || len(rule.Content) != 4 {
		return fmt.Errorf("rule must contain only tool and decision")
	}
	seen := make(map[string]bool, 2)
	for i := 0; i < len(rule.Content); i += 2 {
		key, value := rule.Content[i], rule.Content[i+1]
		if key.Tag != yamlStringTag || (key.Value != "tool" && key.Value != "decision") || seen[key.Value] {
			return fmt.Errorf("expected unique tool and decision fields")
		}
		seen[key.Value] = true
		if err := validatePolicyValue(key.Value, value); err != nil {
			return err
		}
	}
	return nil
}

func validatePolicyValue(field string, value *yaml.Node) error {
	if value.Kind != yaml.ScalarNode || value.Tag != yamlStringTag {
		return fmt.Errorf("%s must be a string", field)
	}
	if field == "tool" && strings.TrimSpace(value.Value) == "" {
		return fmt.Errorf("tool must not be blank")
	}
	if field == "decision" && value.Value != policyAllowValue && value.Value != policyDenyValue && value.Value != policyHITLValue {
		return fmt.Errorf("decision must be allow, deny, or require_hitl")
	}
	return nil
}

func (p *FilePolicy) Evaluate(_ context.Context, pc PolicyContext) PolicyDecision {
	for _, rule := range p.rules {
		if matchTool(rule.Tool, pc.ToolName) {
			switch rule.Decision {
			case policyDenyValue:
				return PolicyDeny
			case policyHITLValue:
				return PolicyRequireHITL
			case policyAllowValue:
				return PolicyAllow
			default:
				slog.Error("agent/policy: invalid decision, denying tool", "tool", pc.ToolName)
				return PolicyDeny
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
		return "", fmt.Errorf("%w: tool is not permitted", ErrToolDenied)
	case PolicyRequireHITL:
		if h.hitl != nil {
			approved, err := h.hitl.RequestApproval(ctx, sessionKey, toolName, args)
			if err != nil {
				return "", err
			}
			if !approved {
				return "", fmt.Errorf("%w: approval not granted", ErrToolDenied)
			}
			return "", nil
		}
		return "", fmt.Errorf("%w: HITL not configured", ErrToolDenied)
	case PolicyAllow:
		return "", nil
	default:
		return "", nil
	}
}
