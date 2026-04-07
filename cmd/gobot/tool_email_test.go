package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/integrations/google"
)

func TestSendEmailTool_Basic(t *testing.T) {
	t.Parallel()

	tool := newSendEmailTool("/tmp/secrets", "user@example.com")

	t.Run("Name", func(t *testing.T) {
		t.Parallel()
		if tool.Name() != sendEmailToolName {
			t.Errorf("Name() = %q, want %q", tool.Name(), sendEmailToolName)
		}
	})

	t.Run("Declaration", func(t *testing.T) {
		t.Parallel()
		decl := tool.Declaration()

		if decl.Name != sendEmailToolName {
			t.Errorf("Declaration.Name = %q, want %q", decl.Name, sendEmailToolName)
		}

		props, _ := decl.Parameters["properties"].(map[string]any)
		if _, ok := props["to"]; ok {
			t.Error("Declaration.Parameters.Properties must NOT contain \"to\" (security constraint)")
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
	})
}

func TestSendEmailTool_Execute_Validation(t *testing.T) {
	t.Parallel()

	tool := newSendEmailTool(t.TempDir(), "user@example.com")

	tests := []struct {
		name    string
		args    map[string]any
		errSub  string
	}{
		{"missing subject key", map[string]any{"body": "Hello"}, "subject is required"},
		{"empty subject string", map[string]any{"subject": "", "body": "Hello"}, "subject is required"},
		{"non-string subject", map[string]any{"subject": 42, "body": "Hello"}, "subject is required"},
		{"missing body key", map[string]any{"subject": "Hello"}, "body is required"},
		{"empty body string", map[string]any{"subject": "Hello", "body": ""}, "body is required"},
		{"non-string body", map[string]any{"subject": "Hello", "body": 99.9}, "body is required"},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			_, err := tool.Execute(context.Background(), "test-session", tt.args)
			if err == nil {
				t.Fatal("Execute() expected error, got nil")
			}
			if !strings.Contains(err.Error(), tt.errSub) {
				t.Errorf("error %q does not contain %q", err.Error(), tt.errSub)
			}
		})
	}
}

func TestSendEmailTool_Execute_AuthFailure(t *testing.T) {
	t.Parallel()

	// An empty secretsRoot has no token.json, so google.NewService will fail.
	tool := newSendEmailTool(t.TempDir(), "user@example.com")
	_, err := tool.Execute(context.Background(), "test-session", map[string]any{
		"subject": "Test subject",
		"body":    "Test body",
	})
	if err == nil {
		t.Fatal("Execute() expected error for missing token, got nil")
	}
	if !strings.Contains(err.Error(), "auth") && !strings.Contains(err.Error(), "token.json") {
		t.Errorf("error %q should mention auth or token.json failure", err.Error())
	}
	_ = google.ErrNeedsReauth // ensure the import is used
}

func TestGmailTools_Declarations(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		tool     Tool
		wantName string
		wantProp string
	}{
		{
			name:     "Search",
			tool:     newSearchGmailTool(t.TempDir()),
			wantName: searchGmailToolName,
			wantProp: "query",
		},
		{
			name:     "Read",
			tool:     newReadGmailTool(t.TempDir()),
			wantName: readGmailToolName,
			wantProp: "message_id",
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			decl := tt.tool.Declaration()
			if decl.Name != tt.wantName {
				t.Errorf("Name = %q, want %q", decl.Name, tt.wantName)
			}
			props, _ := decl.Parameters["properties"].(map[string]any)
			if _, ok := props[tt.wantProp]; !ok {
				t.Errorf("Missing %q property", tt.wantProp)
			}
		})
	}
}

func TestGmailTools_Execute_Validation(t *testing.T) {
	t.Parallel()

	tmp := t.TempDir()
	// Create a dummy token.json to avoid auth errors during arg validation
	// for tests that expect an arg validation error.
	tok := map[string]any{
		"token":  "dummy",
		"expiry": time.Now().Add(1 * time.Hour).Format(time.RFC3339),
	}
	tokData, _ := json.Marshal(tok)
	_ = os.WriteFile(filepath.Join(tmp, "token.json"), tokData, 0600)

	tests := []struct {
		name   string
		tool   Tool
		args   map[string]any
		errSub string
	}{
		{
			name:   "SearchMissingQuery",
			tool:   newSearchGmailTool(tmp),
			args:   map[string]any{},
			errSub: "query is required",
		},
		{
			name:   "ReadMissingID",
			tool:   newReadGmailTool(tmp),
			args:   map[string]any{},
			errSub: "message_id is required",
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			_, err := tt.tool.Execute(context.Background(), "s", tt.args)
			if err == nil {
				t.Error("Expected error for missing required arg")
			}
			if !strings.Contains(err.Error(), tt.errSub) {
				t.Errorf("error %q does not contain %q", err.Error(), tt.errSub)
			}
		})
	}
}
