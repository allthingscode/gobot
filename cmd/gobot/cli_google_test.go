//nolint:testpackage // intentionally uses unexported helpers from main package
package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/integrations/google"
)

//nolint:gocognit // One matrix keeps output and error contracts side by side.
func TestPrintCalendarEvents(t *testing.T) {
	t.Parallel()
	events := []google.CalendarEvent{
		{Summary: "Standup", Start: "2026-04-01T10:00:00Z", Location: "Room 1"},
		{Summary: "Holiday", Start: "2026-04-02", AllDay: true},
	}
	partial := &google.CalendarIncompleteError{Failed: []string{"Family", "Shared"}, Err: errors.New("google API 500")}
	const complete = "No upcoming events."
	cases := []struct {
		name      string
		events    []google.CalendarEvent
		err       error
		want      []string
		reject    []string
		exact     string
		wantErr   string
		wantCause error
	}{
		{name: "healthy", events: events, want: []string{"2026-04-01T10:00:00Z  Standup  @ Room 1", "2026-04-02 (all day)  Holiday"}, reject: []string{"WARNING", complete}},
		{name: "healthy empty", exact: complete + "\n"},
		{name: "mixed success", events: events[:1], err: fmt.Errorf("wrapped: %w", partial), want: []string{"Standup", "WARNING: incomplete schedule; could not load calendar(s): Family, Shared"}, reject: []string{complete}},
		{name: "partial with no healthy events", err: partial, want: []string{"calendars that loaded", "WARNING: incomplete schedule"}, reject: []string{complete + "\n"}},
		{name: "all calendars failed", err: errors.New("calendar events: all 2 calendars failed: google API 500"), wantErr: "all 2 calendars failed"},
		{name: "canceled", err: fmt.Errorf("calendar events: %w", context.Canceled), wantErr: "calendar:", wantCause: context.Canceled},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			var out bytes.Buffer
			err := printCalendarEvents(&out, tc.events, tc.err)
			got := out.String()
			if tc.wantErr != "" {
				if err == nil || got != "" || !strings.HasPrefix(err.Error(), "calendar: ") || !strings.Contains(err.Error(), tc.wantErr) {
					t.Fatalf("output %q err %v, want no output and error containing %q", got, err, tc.wantErr)
				}
				if tc.wantCause != nil && !errors.Is(err, tc.wantCause) {
					t.Fatalf("err %v lost cause %v", err, tc.wantCause)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			assertCalendarOutput(t, got, tc.exact, tc.want, tc.reject)
		})
	}
}

func assertCalendarOutput(t *testing.T, got, exact string, want, reject []string) {
	t.Helper()
	if exact != "" && got != exact {
		t.Fatalf("output %q, want %q", got, exact)
	}
	for _, s := range want {
		if !strings.Contains(got, s) {
			t.Errorf("output %q missing %q", got, s)
		}
	}
	for _, s := range reject {
		if strings.Contains(got, s) {
			t.Errorf("output %q must not contain %q", got, s)
		}
	}
}
