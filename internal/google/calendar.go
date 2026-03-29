package google

import (
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"
)

const calendarBaseURL = "https://www.googleapis.com/calendar/v3"

// CalendarEvent is a simplified view of a Google Calendar event.
type CalendarEvent struct {
	ID           string
	Summary      string
	Start        string // ISO 8601 dateTime or date string
	End          string
	Location     string
	AllDay       bool // true when the event has no time component (date-only)
	CalendarName string // e.g. "Work", "Family", "Holidays in United States"
}

// calendarListEntry is one entry from the calendarList API response.
type calendarListEntry struct {
	ID       string `json:"id"`
	Summary  string `json:"summary"`
	Selected bool   `json:"selected"`
}

// listCalendarsWithClient returns all calendars the user has selected in
// their Google Calendar view (selected=true in calendarList).
func listCalendarsWithClient(token string, client *http.Client) ([]calendarListEntry, error) {
	apiURL := calendarBaseURL + "/users/me/calendarList?minAccessRole=reader"
	var resp struct {
		Items []calendarListEntry `json:"items"`
	}
	if err := apiGet(token, apiURL, client, &resp); err != nil {
		return nil, fmt.Errorf("calendar list: %w", err)
	}
	selected := resp.Items[:0]
	for _, c := range resp.Items {
		if c.Selected {
			selected = append(selected, c)
		}
	}
	return selected, nil
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

	calendars, err := listCalendarsWithClient(token, client)
	if err != nil {
		return nil, err
	}

	now := time.Now().UTC().Format(time.RFC3339)
	perCalParams := url.Values{
		"timeMin":      {now},
		"maxResults":   {fmt.Sprintf("%d", maxResults)},
		"singleEvents": {"true"},
		"orderBy":      {"startTime"},
	}
	paramStr := perCalParams.Encode()

	var all []CalendarEvent
	for _, cal := range calendars {
		apiURL := fmt.Sprintf("%s/calendars/%s/events?%s",
			calendarBaseURL, url.PathEscape(cal.ID), paramStr)

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
			// Log and skip — a shared calendar with expired permissions should
			// not block everything else.
			slog.Warn("calendar: skipping calendar due to fetch error",
				"calendar", cal.Summary, "err", err)
			continue
		}
		for _, item := range resp.Items {
			ev := CalendarEvent{
				ID:           item.ID,
				Summary:      item.Summary,
				Location:     item.Location,
				CalendarName: cal.Summary,
			}
			if item.Start.DateTime != "" {
				ev.Start = item.Start.DateTime
				ev.End = item.End.DateTime
			} else {
				ev.Start = item.Start.Date
				ev.End = item.End.Date
				ev.AllDay = true
			}
			all = append(all, ev)
		}
	}

	// Sort merged results by start time, then trim to maxResults.
	sort.Slice(all, func(i, j int) bool {
		return all[i].Start < all[j].Start
	})
	if len(all) > maxResults {
		all = all[:maxResults]
	}
	return all, nil
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
		calLabel := ""
		if ev.CalendarName != "" {
			calLabel = fmt.Sprintf(" _[%s]_", ev.CalendarName)
		}
		if ev.Location != "" {
			sb.WriteString(fmt.Sprintf("- **%s** — %s _(@ %s)_%s\n", start, label, ev.Location, calLabel))
		} else {
			sb.WriteString(fmt.Sprintf("- **%s** — %s%s\n", start, label, calLabel))
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
