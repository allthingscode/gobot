package reporter

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestFallbackNotify(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name      string
		subject   string
		body      string
		recipient string
		reason    string
		setup     func(storageRoot string)
		wantRet   string
		checkFile func(t *testing.T, storageRoot string)
	}{
		{
			name:      "New file created with header",
			subject:   "Alert",
			body:      "Test body",
			recipient: "user@example.com",
			reason:    "quota_exceeded",
			wantRet:   "Gmail unavailable (quota_exceeded). Report saved to:",
			checkFile: func(t *testing.T, storageRoot string) {
				notifFile := filepath.Join(storageRoot, "workspace", "NOTIFICATIONS.md")
				data, err := os.ReadFile(notifFile)
				if err != nil {
					t.Fatalf("failed to read notifications file: %v", err)
				}
				content := string(data)
				if !strings.HasPrefix(content, "# Strategic Notifications (Fallback)\n") {
					t.Errorf("missing header in new file")
				}
				if !strings.Contains(content, "### [") || !strings.Contains(content, "] Alert") {
					t.Errorf("entry missing subject or timestamp format")
				}
				if !strings.Contains(content, "**To:** user@example.com") {
					t.Errorf("entry missing recipient")
				}
				if !strings.Contains(content, "**Fallback Reason:** quota_exceeded") {
					t.Errorf("entry missing reason")
				}
				if !strings.Contains(content, "Test body") {
					t.Errorf("entry missing body")
				}
			},
		},
		{
			name:      "Append to existing file",
			subject:   "Second",
			body:      "Another one",
			recipient: "user@example.com",
			reason:    "network_error",
			setup: func(storageRoot string) {
				notifFile := filepath.Join(storageRoot, "workspace", "NOTIFICATIONS.md")
				_ = os.MkdirAll(filepath.Dir(notifFile), 0o755)
				_ = os.WriteFile(notifFile, []byte("# Strategic Notifications (Fallback)\n"), 0o600)
			},
			wantRet: "Gmail unavailable (network_error). Report saved to:",
			checkFile: func(t *testing.T, storageRoot string) {
				notifFile := filepath.Join(storageRoot, "workspace", "NOTIFICATIONS.md")
				data, err := os.ReadFile(notifFile)
				if err != nil {
					t.Fatalf("failed to read notifications file: %v", err)
				}
				content := string(data)
				if strings.Count(content, "# Strategic Notifications") != 1 {
					t.Errorf("header should only appear once")
				}
				if !strings.Contains(content, "### [") || !strings.Contains(content, "] Second") {
					t.Errorf("entry missing subject or timestamp format")
				}
			},
		},
		{
			name:      "Auth expired substitution - invalid_grant",
			subject:   "Auth Test",
			body:      "Body",
			recipient: "user@example.com",
			reason:    "Error: invalid_grant",
			wantRet:   "Gmail unavailable (AUTH EXPIRED. Run: gobot reauth). Report saved to:",
			checkFile: func(t *testing.T, storageRoot string) {
				notifFile := filepath.Join(storageRoot, "workspace", "NOTIFICATIONS.md")
				data, err := os.ReadFile(notifFile)
				if err != nil {
					t.Fatalf("failed to read notifications file: %v", err)
				}
				content := string(data)
				if !strings.Contains(content, "**Fallback Reason:** AUTH EXPIRED. Run: gobot reauth") {
					t.Errorf("reason substitution failed")
				}
			},
		},
		{
			name:      "Auth expired substitution - token expired",
			subject:   "Auth Test 2",
			body:      "Body",
			recipient: "user@example.com",
			reason:    "some token expired error",
			wantRet:   "Gmail unavailable (AUTH EXPIRED. Run: gobot reauth). Report saved to:",
			checkFile: func(t *testing.T, storageRoot string) {
				notifFile := filepath.Join(storageRoot, "workspace", "NOTIFICATIONS.md")
				data, err := os.ReadFile(notifFile)
				if err != nil {
					t.Fatalf("failed to read notifications file: %v", err)
				}
				content := string(data)
				if !strings.Contains(content, "**Fallback Reason:** AUTH EXPIRED. Run: gobot reauth") {
					t.Errorf("reason substitution failed")
				}
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			storageRoot := t.TempDir()
			if tt.setup != nil {
				tt.setup(storageRoot)
			}

			got := FallbackNotify(storageRoot, tt.subject, tt.body, tt.recipient, tt.reason)
			if !strings.HasPrefix(got, tt.wantRet) {
				t.Errorf("FallbackNotify() return = %v, want prefix %v", got, tt.wantRet)
			}

			if tt.checkFile != nil {
				tt.checkFile(t, storageRoot)
			}
		})
	}
}

func TestWrapHTML(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name  string
		body  string
		want  string
		match []string
	}{
		{
			name: "Plain text unchanged",
			body: "Hello world",
			want: "Hello world",
		},
		{
			name: "Fragment HTML - header",
			body: "<h1>Title</h1><p>Content</p>",
			match: []string{
				"<!DOCTYPE html>",
				"<html><head><style>",
				emailCSS,
				"color:#f0f6fc !important",
				"color:#a5d6ff !important",
				"Georgia",
				"Cascadia Code",
				"</style></head><body><div class='container'>",
				"<h1>Title</h1><p>Content</p>",
				"</div></body></html>",
			},
		},
		{
			name: "Fragment HTML - paragraph",
			body: "Just a <p>paragraph</p>",
			match: []string{
				"<!DOCTYPE html>",
				"<html><head><style>",
				emailCSS,
				"</style></head><body><div class='container'>",
				"Just a <p>paragraph</p>",
				"</div></body></html>",
			},
		},
		{
			name: "Full HTML with head",
			body: "<html><head><title>Test</title></head><body>Content</body></html>",
			match: []string{
				"<html><head><title>Test</title><style>",
				emailCSS,
				"</style></head><body>Content</body></html>",
			},
		},
		{
			name: "Full HTML without head",
			body: "<html><body>Content</body></html>",
			match: []string{
				"<style>",
				emailCSS,
				"</style><html><body>Content</body></html>",
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got := WrapHTML(tt.body)
			if tt.want != "" {
				if got != tt.want {
					t.Errorf("WrapHTML() = %v, want %v", got, tt.want)
				}
			} else if len(tt.match) > 0 {
				for _, m := range tt.match {
					if !strings.Contains(got, m) {
						t.Errorf("WrapHTML() missing expected content: %v", m)
					}
				}
			}
		})
	}
}

func TestStripHTML(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name  string
		input string
		want  string
	}{
		{
			name:  "plain text unchanged",
			input: "Hello world",
			want:  "Hello world",
		},
		{
			name:  "strips tags",
			input: "<h1>Title</h1><p>Body text</p>",
			want:  "Title\nBody text",
		},
		{
			name:  "br becomes newline",
			input: "Line one<br>Line two",
			want:  "Line one\nLine two",
		},
		{
			name:  "collapses excess blank lines",
			input: "<p>First</p>\n\n\n<p>Second</p>",
			want:  "First\n\nSecond",
		},
		{
			name:  "trims leading/trailing whitespace",
			input: "  <p>Hello</p>  ",
			want:  "Hello",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got := StripHTML(tc.input)
			if got != tc.want {
				t.Errorf("StripHTML(%q)\n got: %q\nwant: %q", tc.input, got, tc.want)
			}
		})
	}
}
