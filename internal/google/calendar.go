package google

import (
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const calendarBaseURL = "https://www.googleapis.com/calendar/v3"

// CalendarEvent is a simplified view of a Google Calendar event.
type CalendarEvent struct {
	ID       string
	Summary  string
	Start    string // ISO 8601 dateTime or date string
	End      string
	Location string
	AllDay   bool // true when the event has no time component (date-only)
}

// ListUpcomingEvents returns up to maxResults upcoming events from the
// primary calendar, ordered by start time. Returns nil slice (not error)
// when the calendar is empty.
func ListUpcomingEvents(secretsRoot string, maxResults int) ([]CalendarEvent, error) {
	return listUpcomingEventsWithClient(secretsRoot, maxResults, http.DefaultClient)
}

func listUpcomingEventsWithClient(secretsRoot string, maxResults int, client *http.Client) ([]CalendarEvent, error) {
	token, err := bearerTokenWithClient(secretsRoot, client)
	if err != nil {
		return nil, fmt.Errorf("calendar auth: %w", err)
	}

	now := time.Now().UTC().Format(time.RFC3339)
	params := url.Values{
		"timeMin":      {now},
		"maxResults":   {fmt.Sprintf("%d", maxResults)},
		"singleEvents": {"true"},
		"orderBy":      {"startTime"},
	}
	apiURL := calendarBaseURL + "/calendars/primary/events?" + params.Encode()

	var resp struct {
		Items []struct {
			ID       string `json:"id"`
			Summary  string `json:"summary"`
			Location string `json:"location"`
			Start    struct {
				DateTime string `json:"dateTime"`
				Date     string `json:"date"`
			} `json:"start"`
			End struct {
				DateTime string `json:"dateTime"`
				Date     string `json:"date"`
			} `json:"end"`
		} `json:"items"`
	}

	if err := apiGet(token, apiURL, client, &resp); err != nil {
		return nil, fmt.Errorf("calendar list: %w", err)
	}

	events := make([]CalendarEvent, 0, len(resp.Items))
	for _, item := range resp.Items {
		ev := CalendarEvent{
			ID:       item.ID,
			Summary:  item.Summary,
			Location: item.Location,
		}
		if item.Start.DateTime != "" {
			ev.Start = item.Start.DateTime
			ev.End = item.End.DateTime
		} else {
			ev.Start = item.Start.Date
			ev.End = item.End.Date
			ev.AllDay = true
		}
		events = append(events, ev)
	}
	return events, nil
}

// FormatEventsMarkdown returns a Markdown bullet list of events for use in
// the system prompt. Returns empty string when events is empty.
func FormatEventsMarkdown(events []CalendarEvent) string {
	if len(events) == 0 {
		return ""
	}
	var sb strings.Builder
	sb.WriteString("### 📅 Upcoming Calendar Events\n")
	for _, ev := range events {
		label := ev.Summary
		if label == "" {
			label = "(no title)"
		}
		start := formatEventTime(ev.Start, ev.AllDay)
		if ev.Location != "" {
			sb.WriteString(fmt.Sprintf("- **%s** — %s _(@ %s)_\n", start, label, ev.Location))
		} else {
			sb.WriteString(fmt.Sprintf("- **%s** — %s\n", start, label))
		}
	}
	return sb.String()
}

// formatEventTime formats an ISO 8601 datetime or date string for display.
func formatEventTime(s string, allDay bool) string {
	if allDay {
		t, err := time.Parse("2006-01-02", s)
		if err != nil {
			return s
		}
		return t.Format("Jan 2") + " (all day)"
	}
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return s
	}
	return t.Local().Format("Mon Jan 2, 3:04 PM")
}
