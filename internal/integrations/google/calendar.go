package google

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"

	"github.com/allthingscode/gobot/internal/logattr"
)

const (
	calendarBaseURL   = "https://www.googleapis.com/calendar/v3"
	primaryCalendarID = "primary"
)

// PrimaryEventTime retains the API's distinction between timed and all-day events.
type PrimaryEventTime struct {
	DateTime string `json:"dateTime,omitempty"`
	Date     string `json:"date,omitempty"`
}

// PrimaryCalendarEvent contains the fetched identity and rescheduling safeguards.
// CalendarID is assigned locally, never accepted from an API response or model.
type PrimaryCalendarEvent struct {
	CalendarID         string            `json:"-"`
	ID                 string            `json:"id"`
	ETag               string            `json:"etag"`
	Summary            string            `json:"summary"`
	Location           string            `json:"location,omitempty"`
	Status             string            `json:"status"`
	EventType          string            `json:"eventType,omitempty"`
	Start              PrimaryEventTime  `json:"start"`
	End                PrimaryEventTime  `json:"end"`
	Recurrence         []string          `json:"recurrence,omitempty"`
	RecurringEventID   string            `json:"recurringEventId,omitempty"`
	OriginalStartTime  *PrimaryEventTime `json:"originalStartTime,omitempty"`
	EndTimeUnspecified bool              `json:"endTimeUnspecified,omitempty"`
}

// ValidateEventTimes compares explicit RFC3339 instants, including offset changes.
func ValidateEventTimes(start, end string) error {
	startTime, err := parseCalendarInstant(start)
	if err != nil {
		return fmt.Errorf("invalid start time (want RFC3339 with offset): %w", err)
	}
	endTime, err := parseCalendarInstant(end)
	if err != nil {
		return fmt.Errorf("invalid end time (want RFC3339 with offset): %w", err)
	}
	if !endTime.After(startTime) {
		return fmt.Errorf("end time must be after start time")
	}
	return nil
}

func parseCalendarInstant(value string) (time.Time, error) {
	instant, err := time.Parse(time.RFC3339, value)
	if err != nil {
		return time.Time{}, fmt.Errorf("parse calendar instant: %w", err)
	}
	// time.Parse accepts single-digit hours, comma fractions and offset 24:00,
	// which RFC3339 does not. Keep the boundary stricter than that parser.
	if len(value) < 20 || value[13] != ':' || value[19] == ',' {
		return time.Time{}, fmt.Errorf("invalid RFC3339 representation")
	}
	if !strings.HasSuffix(value, "Z") {
		zone := value[len(value)-6:]
		if zone[1:3] > "23" || zone[4:6] > "59" {
			return time.Time{}, fmt.Errorf("invalid RFC3339 offset")
		}
	}
	return instant, nil
}

func validatePrimaryEvent(event PrimaryCalendarEvent, eventID string) error {
	if event.CalendarID != primaryCalendarID || eventID == "" || event.ID != eventID {
		return fmt.Errorf("missing or mismatched primary calendar event identity")
	}
	if !validCalendarETag(event.ETag) {
		return fmt.Errorf("missing or unsupported event ETag")
	}
	return validateReschedulableShape(event)
}

func validCalendarETag(etag string) bool {
	return len(etag) >= 3 && etag[0] == '"' && etag[len(etag)-1] == '"' && !strings.ContainsAny(etag[1:len(etag)-1], "\"\r\n")
}

func validateReschedulableShape(event PrimaryCalendarEvent) error {
	if event.Status != "confirmed" && event.Status != "tentative" {
		return fmt.Errorf("event is deleted, cancelled or has unsupported status")
	}
	if hasCalendarRecurrence(event) {
		return fmt.Errorf("recurring masters and instances cannot be rescheduled")
	}
	if event.Start.Date != "" || event.End.Date != "" || event.EndTimeUnspecified || (event.EventType != "" && event.EventType != "default") {
		return fmt.Errorf("all-day or unsupported event shape cannot be rescheduled")
	}
	return ValidateEventTimes(event.Start.DateTime, event.End.DateTime)
}

func hasCalendarRecurrence(event PrimaryCalendarEvent) bool {
	return len(event.Recurrence) != 0 || event.RecurringEventID != "" || event.OriginalStartTime != nil
}

// FindPrimaryCalendarEvents returns up to 50 identity-bearing matches, including
// unsupported shapes so a human can distinguish similarly named events.
func FindPrimaryCalendarEvents(ctx context.Context, secretsRoot, query string) ([]PrimaryCalendarEvent, error) {
	return findPrimaryCalendarEventsWithClient(ctx, secretsRoot, query, TimeoutClient)
}

func findPrimaryCalendarEventsWithClient(ctx context.Context, secretsRoot, query string, client *http.Client) ([]PrimaryCalendarEvent, error) {
	if strings.TrimSpace(query) == "" {
		return nil, fmt.Errorf("calendar lookup: query is required")
	}
	token, err := bearerTokenWithClient(ctx, secretsRoot, client)
	if err != nil {
		return nil, fmt.Errorf("calendar lookup auth: %w", err)
	}
	params := url.Values{"q": {query}, "maxResults": {"50"}, "singleEvents": {"false"}}
	var events []PrimaryCalendarEvent
	seen := map[string]bool{}
	for {
		var page struct {
			Items         []PrimaryCalendarEvent `json:"items"`
			NextPageToken string                 `json:"nextPageToken"`
		}
		if err := apiGet(ctx, token, calendarBaseURL+"/calendars/primary/events?"+params.Encode(), client, &page); err != nil {
			return nil, fmt.Errorf("calendar lookup: %w", err)
		}
		for _, event := range page.Items {
			event.CalendarID = primaryCalendarID
			events = append(events, event)
			if len(events) == 50 {
				return events, nil
			}
		}
		if page.NextPageToken == "" {
			return events, nil
		}
		if seen[page.NextPageToken] {
			return nil, fmt.Errorf("calendar lookup: %w", errCalendarRepeatedPageToken)
		}
		seen[page.NextPageToken] = true
		params.Set("pageToken", page.NextPageToken)
	}
}

// ReschedulePrimaryEvent fetches an exact event and obtains approval for that
// snapshot before one conditional write. approve must perform interactive approval.
func ReschedulePrimaryEvent(ctx context.Context, secretsRoot, eventID, start, end string, approve func(context.Context, PrimaryCalendarEvent) error) error {
	return reschedulePrimaryEventWithClient(ctx, secretsRoot, eventID, start, end, approve, TimeoutClient)
}

func reschedulePrimaryEventWithClient(ctx context.Context, secretsRoot, eventID, start, end string, approve func(context.Context, PrimaryCalendarEvent) error, client *http.Client) error {
	if strings.TrimSpace(eventID) == "" || approve == nil {
		return fmt.Errorf("reschedule requires exact event identity and interactive approval")
	}
	if err := ValidateEventTimes(start, end); err != nil {
		return err
	}
	token, err := bearerTokenWithClient(ctx, secretsRoot, client)
	if err != nil {
		return fmt.Errorf("calendar reschedule auth: %w", err)
	}
	apiURL := calendarBaseURL + "/calendars/primary/events/" + url.PathEscape(eventID)
	var event PrimaryCalendarEvent
	if err := apiGet(ctx, token, apiURL, client, &event); err != nil {
		return fmt.Errorf("fetch selected event: %w", err)
	}
	event.CalendarID = primaryCalendarID
	if err := validatePrimaryEvent(event, eventID); err != nil {
		return fmt.Errorf("selected event: %w", err)
	}
	if err := approve(ctx, event); err != nil {
		return fmt.Errorf("approve selected event: %w", err)
	}
	if err := ctx.Err(); err != nil {
		return fmt.Errorf("before calendar patch: %w", err)
	}
	return patchPrimaryEvent(ctx, token, apiURL, event.ETag, start, end, client)
}

func patchPrimaryEvent(ctx context.Context, token, apiURL, etag, start, end string, client *http.Client) error {
	body := map[string]PrimaryEventTime{"start": {DateTime: start}, "end": {DateTime: end}}
	payload, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("encode calendar times: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPatch, apiURL+"?sendUpdates=all", strings.NewReader(string(payload)))
	if err != nil {
		return fmt.Errorf("build calendar patch: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("If-Match", etag)
	// Redirects must not replay a mutation or move it to another calendar/event.
	patchClient := *client
	patchClient.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	resp, err := patchClient.Do(req)
	if err != nil {
		return fmt.Errorf("calendar patch outcome unknown; inspect event before retrying with fresh approval: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()
	// Do not decode a response after a successful mutation: failure to read it
	// cannot establish that the write failed. No retries, even on transport errors.
	if resp.StatusCode == http.StatusPreconditionFailed {
		return fmt.Errorf("calendar event changed (412); fetch again and obtain fresh approval")
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("calendar patch HTTP %d; inspect event before retrying with fresh approval", resp.StatusCode)
	}
	return nil
}

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
		calendarID = primaryCalendarID
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
