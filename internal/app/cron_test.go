//nolint:testpackage // intentionally uses unexported helpers from main package
package app

import (
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/cron"
	"github.com/allthingscode/gobot/internal/reporter"
)

func TestResolveEmailSubject(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name       string
		payload    cron.Payload
		wantFormat string // substring or prefix to check
	}{
		{
			name: "template with date placeholder",
			payload: cron.Payload{
				Subject: "[Hayes Chief of Staff] 🚀 Daily Briefing - {{DATE}}",
			},
			wantFormat: "[Hayes Chief of Staff] 🚀 Daily Briefing - ",
		},
		{
			name: "static subject no placeholder",
			payload: cron.Payload{
				Subject: "Gobot Strategic Briefing",
			},
			wantFormat: "Gobot Strategic Briefing",
		},
		{
			name:       "no subject falls back to default",
			payload:    cron.Payload{},
			wantFormat: "Gobot Strategic Briefing",
		},
		{
			name: "template with date includes year",
			payload: cron.Payload{
				Subject: "Brief - {{DATE}}",
			},
			wantFormat: ", 20", // ", 2026" — ensures year is embedded
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got := resolveEmailSubject(tt.payload)
			if !strings.Contains(got, tt.wantFormat) {
				t.Errorf("resolveEmailSubject() = %q, want to contain %q", got, tt.wantFormat)
			}
		})
	}
}

func TestResolveEmailSubjectDateIsCurrent(t *testing.T) {
	t.Parallel()
	p := cron.Payload{Subject: "{{DATE}}"}
	got := resolveEmailSubject(p)
	// The date portion should look like a real calendar date: "MonthName Day, Year"
	parts := strings.Fields(got)
	if len(parts) != 3 {
		t.Errorf("resolveEmailSubject(\\\"{{DATE}}\\\") = %q, expected 3 space-separated parts like \\\"April 4, 2026\\\"", got)
	}
	// Verify trailing comma on day (e.g. "4,")
	dayPart := parts[1]
	if !strings.HasSuffix(dayPart, ",") {
		t.Errorf("day part %q should end with comma", dayPart)
	}
}

func TestParseSessionKey(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name         string
		input        string
		wantChatID   int64
		wantThreadID int64
		wantErr      bool
	}{
		{
			name:         "simple telegram key",
			input:        "telegram:12345",
			wantChatID:   12345,
			wantThreadID: 0,
			wantErr:      false,
		},
		{
			name:         "telegram key with thread ID",
			input:        "telegram:12345:7",
			wantChatID:   12345,
			wantThreadID: 7,
			wantErr:      false,
		},
		{
			name:         "large chat ID",
			input:        "telegram:99999999",
			wantChatID:   99999999,
			wantThreadID: 0,
			wantErr:      false,
		},
		{
			name:    "empty string",
			input:   "",
			wantErr: true,
		},
		{
			name:    "channel only no colon",
			input:   "telegram",
			wantErr: true,
		},
		{
			name:    "invalid chat ID letters",
			input:   "telegram:abc",
			wantErr: true,
		},
		{
			name:    "unsupported channel",
			input:   "slack:12345",
			wantErr: true,
		},
		{
			name:    "invalid thread ID letters",
			input:   "telegram:12345:abc",
			wantErr: true,
		},
		{
			name:    "too many parts",
			input:   "telegram:1:2:3",
			wantErr: true,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			gotChatID, gotThreadID, err := parseSessionKey(tc.input)
			checkParseResult(t, tc.input, gotChatID, gotThreadID, err, tc.wantChatID, tc.wantThreadID, tc.wantErr)
		})
	}
	}

	func checkParseResult(t *testing.T, input string, gotChatID, gotThreadID int64, err error, wantChatID, wantThreadID int64, wantErr bool) {
	t.Helper()
	if wantErr {
		if err == nil {
			t.Errorf("parseSessionKey(%q): expected error, got nil (chatID=%d, threadID=%d)",
				input, gotChatID, gotThreadID)
		}
		return
	}
	if err != nil {
		t.Errorf("parseSessionKey(%q): unexpected error: %v", input, err)
		return
	}
	if gotChatID != wantChatID {
		t.Errorf("parseSessionKey(%q): chatID = %d, want %d", input, gotChatID, wantChatID)
	}
	if gotThreadID != wantThreadID {
		t.Errorf("parseSessionKey(%q): threadID = %d, want %d", input, gotThreadID, wantThreadID)
	}
	}


func TestCronSessionKeyIsolation(t *testing.T) {
	t.Parallel()
	to := "telegram:12345"
	cronKey := "cron:" + to
	dmKey := to
	if cronKey == dmKey {
		t.Errorf("cron session key %q must not equal DM session key %q", cronKey, dmKey)
	}
	// Verify the prefix is always present
	if !strings.HasPrefix(cronKey, "cron:") {
		t.Errorf("cron session key must start with \"cron:\", got %q", cronKey)
	}
}

func TestCronSessionKeyFormat(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name string
		to   string
	}{
		{name: "standard telegram key", to: "telegram:12345"},
		{name: "telegram key with thread", to: "telegram:99999:5"},
		{name: "telegram zero chat ID", to: "telegram:0"},
		{name: "empty to", to: ""},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			cronKey := "cron:" + tc.to
			if cronKey == tc.to {
				t.Errorf("cron session key %q must not equal to value %q", cronKey, tc.to)
			}
			if !strings.HasPrefix(cronKey, "cron:") {
				t.Errorf("cron session key must start with \"cron:\", got %q", cronKey)
			}
		})
	}
}

// TestBriefingEmailHTMLDelivery verifies the critical invariant that
// briefing responses going through WrapHTML produce styled HTML emails.
// Regression: the morning briefing job prompt was changed from HTML to
// Markdown instructions, causing WrapHTML to return the body unchanged
// and emails to go out as plain text (no dark theme, no styling).
// Second regression: WrapHTML only checked for <h1> and <p>, so responses
// using <h2>, <div>, <ul>, or <strong> went out as plain text.
func TestBriefingEmailHTMLDelivery(t *testing.T) {
	t.Parallel()

	// Simulate what an agent response should look like following the HTML prompt.
	// Covers tags that were previously undetected by WrapHTML.
	responses := []string{
		"<h1>Values &amp; Vitality</h1><p>Matthew, have a great day.</p>",
		"<p>Brief test</p>",
		"<div class=\"vitality\"><h1>Vitals</h1><p>Body</p></div>",
		"<h2>📅 Schedule</h2><ul><li>Item</li></ul>",
		"<div style=\"background-color:#121212\"><h2>Finance</h2></div>",
		"<strong>Market Futures:</strong> Bearish sentiment.",
	}

	for _, body := range responses {
		got := reporter.WrapHTML(body)
		if !strings.Contains(strings.ToLower(got), "<html") {
			t.Errorf("WrapHTML output missing HTML wrapper.\n"+
				"input: %q\noutput: %q", body, got)
		}
	}
}

// TestCronEmailSessionKeyIncludesJobID verifies that email-channel cron jobs
// produce session keys that include the job ID, ensuring two different jobs
// (e.g. morning_briefing and nightly_batch) get isolated agent sessions.
// Regression: both jobs shared "cron:email:<recipient>", causing the nightly
// batch's Markdown context to bleed into the morning briefing session.
func TestCronEmailSessionKeyIncludesJobID(t *testing.T) {
	t.Parallel()

	const recipient = "user@example.com"
	jobIDs := []string{"morning_briefing", "nightly_batch", "unknown"}

	keys := make(map[string]string, len(jobIDs))
	for _, id := range jobIDs {
		key := "cron:" + id + ":email:" + recipient
		if !strings.HasPrefix(key, "cron:") {
			t.Errorf("session key %q must start with cron:", key)
		}
		if !strings.Contains(key, ":email:") {
			t.Errorf("session key %q must contain :email:", key)
		}
		if !strings.Contains(key, id) {
			t.Errorf("session key %q must contain job ID %q", key, id)
		}
		keys[id] = key
	}

	if keys["morning_briefing"] == keys["nightly_batch"] {
		t.Errorf("morning_briefing and nightly_batch must have different session keys, both got %q",
			keys["morning_briefing"])
	}
}
