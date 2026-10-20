package google

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"

	"github.com/allthingscode/gobot/internal/logattr"
)

const calendarBaseURL = "https://www.googleapis.com/calendar/v3"

// errCalendarRepeatedPageToken marks a continuation token the API already returned, which would loop forever.
var errCalendarRepeatedPageToken = errors.New("repeated pagination token prevents progress")

// CalendarEvent is a simplified view of a Google Calendar event.
type CalendarEvent struct {
	ID           string
	Summary      string
	Start        string // ISO 8601 dateTime or date string
	End          string
	Location     string
	AllDay       bool   // true when the event has no time component (date-only)
	CalendarName string // e.g. "Work", "Family", "Holidays in United States"
}

// calendarListEntry is one entry from the calendarList API response.
type calendarListEntry struct {
	ID       string `json:"id"`
	Summary  string `json:"summary"`
	Selected bool   `json:"selected"`
}

// listCalendarsWithClient returns all calendars the user has reader access to.
func listCalendarsWithClient(ctx context.Context, token string, client *http.Client) ([]calendarListEntry, error) {
	params := url.Values{"minAccessRole": {"reader"}}
	var all []calendarListEntry
	seen := map[string]struct{}{}
	for {
		var resp struct {
			Items         []calendarListEntry `json:"items"`
			NextPageToken string              `json:"nextPageToken"`
		}
		if err := apiGet(ctx, token, calendarBaseURL+"/users/me/calendarList?"+params.Encode(), client, &resp); err != nil {
			return nil, fmt.Errorf("calendar list: %w", err)
		}
		all = append(all, resp.Items...)
		if resp.NextPageToken == "" {
			return all, nil
		}
		if _, dup := seen[resp.NextPageToken]; dup {
			return nil, fmt.Errorf("calendar list: %w", errCalendarRepeatedPageToken)
		}
		seen[resp.NextPageToken] = struct{}{}
		params.Set("pageToken", resp.NextPageToken)
	}
}

// CalendarIncompleteError reports that some calendars failed while the others
// loaded, so the events returned alongside it are not the complete schedule.
type CalendarIncompleteError struct {
	Failed []string // names of the calendars that could not be loaded
	Err    error    // first per-calendar failure
}

// Error implements error.
func (e *CalendarIncompleteError) Error() string {
	return fmt.Sprintf("calendar events incomplete: %d calendar(s) failed (%s): %v", len(e.Failed), strings.Join(e.Failed, ", "), e.Err)
}

// Unwrap returns the first per-calendar failure.
func (e *CalendarIncompleteError) Unwrap() error { return e.Err }

// ListUpcomingEvents returns up to maxResults upcoming events across every
// readable calendar, ordered by start time.
//
// A nil error means every calendar loaded; an empty result is then a genuinely
// empty schedule. When some but not all calendars fail, it returns the healthy
// events together with a *CalendarIncompleteError, so callers must check
// errors.As before treating the error as fatal. When every calendar fails, or
// ctx is canceled or past its deadline, it returns nil events and an error.
func ListUpcomingEvents(ctx context.Context, secretsRoot string, maxResults int) ([]CalendarEvent, error) {
	return listUpcomingEventsWithClient(ctx, secretsRoot, maxResults, TimeoutClient)
}

func listUpcomingEventsWithClient(ctx context.Context, secretsRoot string, maxResults int, client *http.Client) ([]CalendarEvent, error) {
	token, err := bearerTokenWithClient(ctx, secretsRoot, client)
	if err != nil {
		return nil, fmt.Errorf("calendar auth: %w", err)
	}

	calendars, err := listCalendarsWithClient(ctx, token, client)
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
	var all []CalendarEvent
	var failed []string
	var firstErr error
	for _, cal := range calendars {
		if err := ctx.Err(); err != nil {
			return nil, fmt.Errorf("calendar events: %w", err)
		}
		events, err := listCalendarEventsWithClient(ctx, token, cal, perCalParams, maxResults, client)
		if err != nil {
			// The parent ctx, not the fetch error, decides cancellation: a per-request
			// client timeout also satisfies errors.Is(err, context.DeadlineExceeded).
			if ctxErr := ctx.Err(); ctxErr != nil {
				return nil, fmt.Errorf("calendar events: %w", ctxErr)
			}
			// A shared calendar failure must not block other calendars or leak partial pages.
			slog.Warn("calendar: skipping calendar due to fetch error",
				slog.String("calendar", cal.Summary), logattr.Err(err))
			failed = append(failed, calendarLabel(cal))
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		all = append(all, events...)
	}
	if err := ctx.Err(); err != nil {
		return nil, fmt.Errorf("calendar events: %w", err)
	}
	return finishCalendarEvents(all, failed, firstErr, len(calendars), maxResults)
}

// finishCalendarEvents applies the completeness contract documented on ListUpcomingEvents.
func finishCalendarEvents(all []CalendarEvent, failed []string, firstErr error, total, maxResults int) ([]CalendarEvent, error) {
	if len(failed) > 0 && len(failed) == total {
		return nil, fmt.Errorf("calendar events: all %d calendars failed: %w", total, firstErr)
	}
	sortCalendarEvents(all)
	if len(all) > maxResults {
		all = all[:maxResults]
	}
	if len(failed) > 0 {
		return all, &CalendarIncompleteError{Failed: failed, Err: firstErr}
	}
	return all, nil
}

// calendarLabel names a calendar for failure reports, falling back to its ID.
func calendarLabel(cal calendarListEntry) string {
	if cal.Summary != "" {
		return cal.Summary
	}
	return cal.ID
}

// listCalendarEventsWithClient collects enough ordered events before publishing a calendar.
func listCalendarEventsWithClient(ctx context.Context, token string, cal calendarListEntry, filters url.Values, maxResults int, client *http.Client) ([]CalendarEvent, error) {
	params := url.Values{}
	for key, values := range filters {
		params[key] = append([]string(nil), values...)
	}
	var events []CalendarEvent
	seen := map[string]struct{}{}
	for {
		apiURL := fmt.Sprintf("%s/calendars/%s/events?%s", calendarBaseURL, url.PathEscape(cal.ID), params.Encode())
		var resp struct {
			NextPageToken string `json:"nextPageToken"`
			Items         []struct {
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
		if err := apiGet(ctx, token, apiURL, client, &resp); err != nil {
			return nil, fmt.Errorf("calendar events: %w", err)
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
			events = append(events, ev)
		}
		if resp.NextPageToken == "" || len(events) >= maxResults {
			return events, nil
		}
		if _, dup := seen[resp.NextPageToken]; dup {
			return nil, fmt.Errorf("calendar events: %w", errCalendarRepeatedPageToken)
		}
		seen[resp.NextPageToken] = struct{}{}
		params.Set("pageToken", resp.NextPageToken)
	}
}

// sortCalendarEvents orders merged events by instant while preserving ties.
func sortCalendarEvents(all []CalendarEvent) {
	// All-day dates use midnight UTC only for ordering. Parse each start once
	// and preserve the original event fields for callers and display formatting.
	type sortRecord struct {
		event CalendarEvent
		start time.Time
		valid bool
	}
	records := make([]sortRecord, len(all))
	for i, event := range all {
		layout := time.RFC3339
		if event.AllDay {
			layout = "2006-01-02"
		}
		start, err := time.Parse(layout, event.Start)
		records[i] = sortRecord{event: event, start: start, valid: err == nil}
	}
	// Invalid starts follow valid keys. Ties retain merge order, before limiting.
	sort.SliceStable(records, func(i, j int) bool {
		if records[i].valid != records[j].valid {
			return records[i].valid
		}
		return records[i].valid && records[i].start.Before(records[j].start)
	})
	for i, record := range records {
		all[i] = record.event
	}
}

// CreateEvent creates a new event in the specified Google Calendar and returns
// the created event's ID. calendarID defaults to "primary" when empty.
// start and end must be valid RFC3339 (ISO 8601) strings.
func CreateEvent(ctx context.Context, secretsRoot, calendarID, summary, description, start, end, location string) (string, error) {
	return createEventWithClient(ctx, secretsRoot, calendarID, summary, description, start, end, location, TimeoutClient)
}

func createEventWithClient(ctx context.Context, secretsRoot, calendarID, summary, description, start, end, location string, client *http.Client) (string, error) {
	if _, err := time.Parse(time.RFC3339, start); err != nil {
		return "", fmt.Errorf("invalid start time (want RFC3339): %w", err)
	}
	if _, err := time.Parse(time.RFC3339, end); err != nil {
		return "", fmt.Errorf("invalid end time (want RFC3339): %w", err)
	}

	token, err := bearerTokenWithClient(ctx, secretsRoot, client)
	if err != nil {
		return "", fmt.Errorf("calendar auth: %w", err)
	}

	if calendarID == "" {
		calendarID = "primary"
	}

	type eventTime struct {
		DateTime string `json:"dateTime"`
	}
	body := map[string]any{
		"summary": summary,
		"start":   eventTime{DateTime: start},
		"end":     eventTime{DateTime: end},
	}
	if description != "" {
		body["description"] = description
	}
	if location != "" {
		body["location"] = location
	}

	apiURL := fmt.Sprintf("%s/calendars/%s/events", calendarBaseURL, url.PathEscape(calendarID))
	var created struct {
		ID string `json:"id"`
	}
	if err := apiPost(ctx, token, apiURL, body, client, &created); err != nil {
		return "", fmt.Errorf("calendar create event: %w", err)
	}
	return created.ID, nil
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
			fmt.Fprintf(&sb, "- **%s** — %s _(@ %s)_%s\n", start, label, ev.Location, calLabel)
		} else {
			fmt.Fprintf(&sb, "- **%s** — %s%s\n", start, label, calLabel)
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
