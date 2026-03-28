package google

import (
	"strings"
	"testing"
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
