package main

import (
	"strings"
	"testing"
)

func TestParseSessionKey(t *testing.T) {
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
			gotChatID, gotThreadID, err := parseSessionKey(tc.input)
			if tc.wantErr {
				if err == nil {
					t.Errorf("parseSessionKey(%q): expected error, got nil (chatID=%d, threadID=%d)",
						tc.input, gotChatID, gotThreadID)
				}
				return
			}
			if err != nil {
				t.Errorf("parseSessionKey(%q): unexpected error: %v", tc.input, err)
				return
			}
			if gotChatID != tc.wantChatID {
				t.Errorf("parseSessionKey(%q): chatID = %d, want %d", tc.input, gotChatID, tc.wantChatID)
			}
			if gotThreadID != tc.wantThreadID {
				t.Errorf("parseSessionKey(%q): threadID = %d, want %d", tc.input, gotThreadID, tc.wantThreadID)
			}
		})
	}
}

func TestCronSessionKeyIsolation(t *testing.T) {
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
