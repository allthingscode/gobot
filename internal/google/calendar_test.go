package google

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestFormatEventsMarkdown_Empty(t *testing.T) {
	if got := FormatEventsMarkdown(nil); got != "" {
		t.Errorf("expected empty string for nil events, got %q", got)
	}
}

func TestFormatEventsMarkdown_TimedEvent(t *testing.T) {
	events := []CalendarEvent{
		{Summary: "Team Standup", Start: "2026-03-28T09:00:00-05:00"},
	}
	out := FormatEventsMarkdown(events)
	if !strings.Contains(out, "Team Standup") {
		t.Errorf("expected 'Team Standup' in output:\n%s", out)
	}
	if !strings.Contains(out, "📅") {
		t.Errorf("expected calendar emoji in output:\n%s", out)
	}
}

func TestFormatEventsMarkdown_AllDayEvent(t *testing.T) {
	events := []CalendarEvent{
		{Summary: "Company Holiday", Start: "2026-03-28", AllDay: true},
	}
	out := FormatEventsMarkdown(events)
	if !strings.Contains(out, "Company Holiday") {
		t.Errorf("expected 'Company Holiday' in output:\n%s", out)
	}
	if !strings.Contains(out, "all day") {
		t.Errorf("expected 'all day' marker in output:\n%s", out)
	}
}

func TestFormatEventsMarkdown_WithLocation(t *testing.T) {
	events := []CalendarEvent{
		{Summary: "Doctor", Start: "2026-03-28T14:00:00-05:00", Location: "123 Main St"},
	}
	out := FormatEventsMarkdown(events)
	if !strings.Contains(out, "123 Main St") {
		t.Errorf("expected location in output:\n%s", out)
	}
}

func TestFormatEventsMarkdown_NoTitle(t *testing.T) {
	events := []CalendarEvent{
		{Start: "2026-03-28T10:00:00-05:00"},
	}
	out := FormatEventsMarkdown(events)
	if !strings.Contains(out, "(no title)") {
		t.Errorf("expected '(no title)' placeholder:\n%s", out)
	}
}

func TestFormatEventTime_AllDay(t *testing.T) {
	got := formatEventTime("2026-03-28", true)
	if !strings.Contains(got, "all day") {
		t.Errorf("expected 'all day' in %q", got)
	}
	if !strings.Contains(got, "Mar") {
		t.Errorf("expected month abbreviation in %q", got)
	}
}

func TestFormatEventTime_Timed(t *testing.T) {
	got := formatEventTime("2026-03-28T09:00:00Z", false)
	// Should contain AM/PM
	if !strings.Contains(got, "AM") && !strings.Contains(got, "PM") {
		t.Errorf("expected AM/PM in timed event format %q", got)
	}
}

func TestFormatEventTime_InvalidFallsBack(t *testing.T) {
	raw := "not-a-date"
	got := formatEventTime(raw, false)
	if got != raw {
		t.Errorf("expected raw fallback for invalid date, got %q", got)
	}
}

func TestListUpcomingEventsWithClient(t *testing.T) {
	cases := []struct {
		name      string
		items     []map[string]any
		wantCount int
		wantAllDay bool
		wantSummary string
	}{
		{
			name: "timed event",
			items: []map[string]any{
				{
					"id": "1", "summary": "Team Sync",
					"start": map[string]string{"dateTime": "2026-03-28T09:00:00Z"},
					"end":   map[string]string{"dateTime": "2026-03-28T10:00:00Z"},
				},
			},
			wantCount:   1,
			wantSummary: "Team Sync",
			wantAllDay:  false,
		},
		{
			name: "all-day event",
			items: []map[string]any{
				{
					"id": "2", "summary": "Company Holiday",
					"start": map[string]string{"date": "2026-03-28"},
					"end":   map[string]string{"date": "2026-03-29"},
				},
			},
			wantCount:   1,
			wantSummary: "Company Holiday",
			wantAllDay:  true,
		},
		{
			name:      "empty calendar",
			items:     []map[string]any{},
			wantCount: 0,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				json.NewEncoder(w).Encode(map[string]any{"items": tc.items})
			}))
			defer srv.Close()

			dir := t.TempDir()
			writeToken(t, dir, storedToken{
				Token:  "access",
				Expiry: time.Now().Add(1 * time.Hour),
			})

			client := redirectClient(calendarBaseURL, srv.URL)
			events, err := listUpcomingEventsWithClient(dir, 10, client)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(events) != tc.wantCount {
				t.Fatalf("want %d events, got %d", tc.wantCount, len(events))
			}
			if tc.wantCount > 0 {
				if events[0].Summary != tc.wantSummary {
					t.Errorf("want summary %q, got %q", tc.wantSummary, events[0].Summary)
				}
				if events[0].AllDay != tc.wantAllDay {
					t.Errorf("want AllDay=%v, got %v", tc.wantAllDay, events[0].AllDay)
				}
			}
		})
	}
}

func TestListUpcomingEventsWithClient_AuthError(t *testing.T) {
	_, err := listUpcomingEventsWithClient(t.TempDir(), 10, http.DefaultClient)
	if err == nil {
		t.Fatal("expected error for missing token file")
	}
}
