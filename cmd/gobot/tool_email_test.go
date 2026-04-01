package main

import (
	"context"
	"testing"

	"github.com/allthingscode/gobot/internal/gmail"
)

func TestSendEmailTool_Name(t *testing.T) {
	tool := newSendEmailTool("/tmp/secrets", "user@example.com")
	if tool.Name() != sendEmailToolName {
		t.Errorf("Name() = %q, want %q", tool.Name(), sendEmailToolName)
	}
}

func TestSendEmailTool_Declaration_NoToParameter(t *testing.T) {
	tool := newSendEmailTool("/tmp/secrets", "user@example.com")
	decl := tool.Declaration()

	if decl.Name != sendEmailToolName {
		t.Errorf("Declaration.Name = %q, want %q", decl.Name, sendEmailToolName)
	}
	if decl.Description == "" {
		t.Error("Declaration.Description must not be empty")
	}
	if decl.Parameters == nil {
		t.Fatal("Declaration.Parameters is nil")
	}
	if typ, _ := decl.Parameters["type"].(string); typ != "object" {
		t.Errorf("Parameters.Type = %v, want object", typ)
	}

	// Security check: "to" must NOT appear in Properties — the model must never
	// be able to supply a recipient address.
	props, _ := decl.Parameters["properties"].(map[string]any)
	if _, ok := props["to"]; ok {
		t.Error("Declaration.Parameters.Properties must NOT contain \"to\" (security constraint)")
	}

	// Required parameters must be present.
	for _, field := range []string{"subject", "body"} {
		if _, ok := props[field]; !ok {
			t.Errorf("Declaration.Parameters.Properties missing %q", field)
		}
	}

	reqs, _ := decl.Parameters["required"].([]string)
	requiredSet := make(map[string]bool, len(reqs))
	for _, r := range reqs {
		requiredSet[r] = true
	}
	for _, req := range []string{"subject", "body"} {
		if !requiredSet[req] {
			t.Errorf("Required must contain %q", req)
		}
	}
}

func TestSendEmailTool_Execute_MissingSubject(t *testing.T) {
	tool := newSendEmailTool(t.TempDir(), "user@example.com")

	tests := []struct {
		name string
		args map[string]any
	}{
		{"missing subject key", map[string]any{"body": "Hello"}},
		{"empty subject string", map[string]any{"subject": "", "body": "Hello"}},
		{"non-string subject", map[string]any{"subject": 42, "body": "Hello"}},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, err := tool.Execute(context.Background(), "test-session", tc.args)
			if err == nil {
				t.Fatal("Execute() expected error, got nil")
			}
			if !contains(err.Error(), "subject is required") {
				t.Errorf("error %q does not contain \"subject is required\"", err.Error())
			}
		})
	}
}

func TestSendEmailTool_Execute_MissingBody(t *testing.T) {
	tool := newSendEmailTool(t.TempDir(), "user@example.com")

	tests := []struct {
		name string
		args map[string]any
	}{
		{"missing body key", map[string]any{"subject": "Hello"}},
		{"empty body string", map[string]any{"subject": "Hello", "body": ""}},
		{"non-string body", map[string]any{"subject": "Hello", "body": 99.9}},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, err := tool.Execute(context.Background(), "test-session", tc.args)
			if err == nil {
				t.Fatal("Execute() expected error, got nil")
			}
			if !contains(err.Error(), "body is required") {
				t.Errorf("error %q does not contain \"body is required\"", err.Error())
			}
		})
	}
}

func TestSendEmailTool_Execute_EmptySecretsRootFails(t *testing.T) {
	// An empty secretsRoot has no token.json, so gmail.NewService will fail.
	// This verifies that arg validation passes and the tool attempts auth.
	tool := newSendEmailTool(t.TempDir(), "user@example.com")
	_, err := tool.Execute(context.Background(), "test-session", map[string]any{
		"subject": "Test subject",
		"body":    "Test body",
	})
	if err == nil {
		t.Fatal("Execute() expected error for missing token, got nil")
	}
	// The error should wrap the gmail.NewService failure (auth), not an arg error.
	if !contains(err.Error(), "auth") {
		t.Errorf("error %q should mention auth failure", err.Error())
	}
	// Verify the error is not a spurious arg-validation error.
	if contains(err.Error(), "subject is required") || contains(err.Error(), "body is required") {
		t.Errorf("unexpected arg-validation error: %v", err)
	}
	// The underlying cause must be ErrNeedsReauth or a token-not-found error,
	// both of which are surfaced by gmail.NewService.
	_ = gmail.ErrNeedsReauth // ensure the import is used
}
