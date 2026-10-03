//nolint:testpackage // Exercises strict loader and defensive in-memory evaluation.
package agent

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

//nolint:gocognit // Table covers required strict-schema failure classes and success cases.
func TestPolicySchema(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name, content string
		valid         bool
	}{
		{"empty", "", false},
		{"comments", "# comment", false},
		{"missing rules", "{}", false},
		{"null rules", "rules: null", false},
		{"scalar rules", "rules: allow", false},
		{"mapping rules", "rules: {}", false},
		{"scalar root", "allow", false},
		{"sequence root", "[]", false},
		{"non mapping rule", "rules: [allow]", false},
		{"missing tool", "rules: [{decision: deny}]", false},
		{"null tool", "rules: [{tool: null, decision: deny}]", false},
		{"blank tool", "rules: [{tool: '  ', decision: deny}]", false},
		{"numeric tool", "rules: [{tool: 42, decision: deny}]", false},
		{"boolean tool", "rules: [{tool: true, decision: deny}]", false},
		{"sequence tool", "rules: [{tool: [], decision: deny}]", false},
		{"missing decision", "rules: [{tool: x}]", false},
		{"null decision", "rules: [{tool: x, decision: null}]", false},
		{"numeric decision", "rules: [{tool: x, decision: 42}]", false},
		{"unknown decision", "rules: [{tool: x, decision: typo}]", false},
		{"unreachable invalid", "rules: [{tool: '*', decision: allow}, {tool: x, decision: typo}]", false},
		{"unknown root key", "rules: []\nextra: true", false},
		{"old policies", "policies: [{name: test, tool: '*', decision: allow}]", false},
		{"unknown rule key", "rules: [{tool: x, decision: deny, name: test}]", false},
		{"duplicate root key", "rules: []\nrules: []", false},
		{"duplicate tool", "rules: [{tool: x, tool: y}]", false},
		{"duplicate decision", "rules: [{decision: deny, decision: allow}]", false},
		{"duplicate extra field", "rules: [{tool: x, decision: deny, tool: y}]", false},
		{"multiple documents", "rules: []\n---\nrules: []", false},
		{"trailing empty document", "rules: []\n---", false},
		{"trailing malformed", "rules: []\n---\n[", false},
		{"empty rules", "rules: []", true},
		{"valid", "rules: [{tool: x, decision: deny}]", true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			path := filepath.Join(t.TempDir(), "policy.yaml")
			if err := os.WriteFile(path, []byte(tt.content), 0o600); err != nil {
				t.Fatal(err)
			}
			p, err := NewFilePolicy(path)
			if tt.valid {
				if err != nil || p == nil {
					t.Fatalf("valid policy: %v", err)
				}
				return
			}
			if err == nil || p != nil || !strings.Contains(err.Error(), strconv.Quote(path)) {
				t.Fatalf("expected contextual failure, got %v, %v", p, err)
			}
		})
	}
}

func TestPolicyDirectory(t *testing.T) {
	t.Parallel()
	p, err := NewFilePolicy(t.TempDir())
	if err == nil || p != nil {
		t.Fatalf("directory must fail: %v, %v", p, err)
	}
}

func TestPolicyOrderedEvaluation(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name, rules, tool string
		want              PolicyDecision
	}{
		{"exact allow", "[{tool: x, decision: allow}, {tool: '*', decision: deny}]", "x", PolicyAllow},
		{"wildcard deny", "[{tool: x, decision: allow}, {tool: '*', decision: deny}]", "other", PolicyDeny},
		{"wildcard first", "[{tool: '*', decision: require_hitl}, {tool: x, decision: allow}]", "x", PolicyRequireHITL},
		{"unmatched", "[{tool: x, decision: deny}]", "other", PolicyAllow},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			path := filepath.Join(t.TempDir(), "policy.yaml")
			if err := os.WriteFile(path, []byte("rules: "+tt.rules), 0o600); err != nil {
				t.Fatal(err)
			}
			p, err := NewFilePolicy(path)
			if err != nil {
				t.Fatal(err)
			}
			if got := p.Evaluate(context.Background(), PolicyContext{ToolName: tt.tool}); got != tt.want {
				t.Fatalf("got %v, want %v", got, tt.want)
			}
		})
	}
}
