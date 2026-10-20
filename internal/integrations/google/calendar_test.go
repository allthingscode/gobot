//nolint:testpackage // requires unexported calendar internals for testing
package google

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestFormatEventsMarkdown_Empty(t *testing.T) {
	t.Parallel()
	if got := FormatEventsMarkdown(nil); got != "" {
		t.Errorf("expected empty string for nil events, got %q", got)
	}
}

func TestFormatEventsMarkdown_TimedEvent(t *testing.T) {
	t.Parallel()
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
	t.Parallel()
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
	t.Parallel()
	events := []CalendarEvent{
		{Summary: "Doctor", Start: "2026-03-28T14:00:00-05:00", Location: "123 Main St"},
	}
	out := FormatEventsMarkdown(events)
	if !strings.Contains(out, "123 Main St") {
		t.Errorf("expected location in output:\n%s", out)
	}
}

func TestFormatEventsMarkdown_NoTitle(t *testing.T) {
	t.Parallel()
	events := []CalendarEvent{
		{Start: "2026-03-28T10:00:00-05:00"},
	}
	out := FormatEventsMarkdown(events)
	if !strings.Contains(out, "(no title)") {
		t.Errorf("expected '(no title)' placeholder:\n%s", out)
	}
}

func TestFormatEventTime_AllDay(t *testing.T) {
	t.Parallel()
	got := formatEventTime("2026-03-28", true)
	if !strings.Contains(got, "all day") {
		t.Errorf("expected 'all day' in %q", got)
	}
	if !strings.Contains(got, "Mar") {
		t.Errorf("expected month abbreviation in %q", got)
	}
}

func TestFormatEventTime_Timed(t *testing.T) {
	t.Parallel()
	got := formatEventTime("2026-03-28T09:00:00Z", false)
	// Should contain AM/PM
	if !strings.Contains(got, "AM") && !strings.Contains(got, "PM") {
		t.Errorf("expected AM/PM in timed event format %q", got)
	}
}

func TestFormatEventTime_InvalidFallsBack(t *testing.T) {
	t.Parallel()
	raw := "not-a-date"
	got := formatEventTime(raw, false)
	if got != raw {
		t.Errorf("expected raw fallback for invalid date, got %q", got)
	}
}

func TestListUpcomingEventsWithClient(t *testing.T) {
	t.Parallel()

	t.Run("Success", func(t *testing.T) {
		t.Parallel()
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			switch {
			case strings.Contains(r.URL.Path, "calendarList"):
				_ = json.NewEncoder(w).Encode(map[string]any{
					"items": []calendarListEntry{
						{ID: "primary", Summary: "Main", Selected: true},
					},
				})
			case strings.Contains(r.URL.Path, "events"):
				_ = json.NewEncoder(w).Encode(map[string]any{
					"items": []map[string]any{
						{
							"id": "e1", "summary": "Test Event",
							"start": map[string]string{"dateTime": "2026-04-01T10:00:00Z"},
							"end":   map[string]string{"dateTime": "2026-04-01T11:00:00Z"},
						},
					},
				})
			}
		}))
		defer srv.Close()

		dir := setupTestToken(t)
		client := redirectClient(calendarBaseURL, srv.URL)

		events, err := listUpcomingEventsWithClient(context.Background(), dir, 10, client)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		validateCalendarEvents(t, events, 1, "Test Event", "Main")
	})
}

func validateCalendarEvents(t *testing.T, events []CalendarEvent, wantCount int, wantSummary, wantCalName string) {
	t.Helper()
	if len(events) != wantCount {
		t.Errorf("got %d events, want %d", len(events), wantCount)
		return
	}
	if wantCount > 0 {
		if events[0].Summary != wantSummary {
			t.Errorf("got summary %q, want %q", events[0].Summary, wantSummary)
		}
		if events[0].CalendarName != wantCalName {
			t.Errorf("got calendar %q, want %q", events[0].CalendarName, wantCalName)
		}
	}
}

func TestListUpcomingEventsWithClient_AuthError(t *testing.T) {
	t.Parallel()
	_, err := listUpcomingEventsWithClient(context.Background(), t.TempDir(), 10, http.DefaultClient)
	if err == nil {
		t.Fatal("expected error for missing token file")
	}
}

func TestListUpcomingEventsWithClient_MultipleCalendars(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.Contains(r.URL.Path, "calendarList"):
			_ = json.NewEncoder(w).Encode(map[string]any{
				"items": []calendarListEntry{
					{ID: "c1", Summary: "Work", Selected: true},
					{ID: "c2", Summary: "Home", Selected: true},
				},
			})
		case strings.Contains(r.URL.Path, "c1/events"):
			_ = json.NewEncoder(w).Encode(map[string]any{
				"items": []map[string]any{
					{"id": "e1", "summary": "Meeting", "start": map[string]string{"dateTime": "2026-04-01T09:00:00Z"}},
				},
			})
		case strings.Contains(r.URL.Path, "c2/events"):
			_ = json.NewEncoder(w).Encode(map[string]any{
				"items": []map[string]any{
					{"id": "e2", "summary": "Dinner", "start": map[string]string{"dateTime": "2026-04-01T19:00:00Z"}},
				},
			})
		}
	}))
	defer srv.Close()

	dir := setupTestToken(t)
	client := redirectClient(calendarBaseURL, srv.URL)

	events, err := listUpcomingEventsWithClient(context.Background(), dir, 10, client)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(events) != 2 {
		t.Errorf("got %d events, want 2", len(events))
	}
}

func setupTestToken(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	tok := storedToken{Token: "fake", Expiry: time.Now().Add(1 * time.Hour)}
	writeToken(t, dir, tok)
	return dir
}

func TestListUpcomingEventsWithClient_UnselectedCalendarIncluded(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.Contains(r.URL.Path, "calendarList"):
			// Both selected:false and selected:true are fetched by ListUpcomingEvents
			// because it uses minAccessRole=reader, not Selected status.
			_ = json.NewEncoder(w).Encode(map[string]any{
				"items": []calendarListEntry{
					{ID: "c1", Summary: "Shared", Selected: false},
				},
			})
		case strings.Contains(r.URL.Path, "events"):
			_ = json.NewEncoder(w).Encode(map[string]any{
				"items": []map[string]any{
					{"id": "e1", "summary": "Visible", "start": map[string]string{"dateTime": "2026-04-01T10:00:00Z"}},
				},
			})
		}
	}))
	defer srv.Close()

	dir := setupTestToken(t)
	client := redirectClient(calendarBaseURL, srv.URL)

	_, err := listUpcomingEventsWithClient(context.Background(), dir, 10, client)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestListUpcomingEventsWithClient_Empty(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.Path, "calendarList") {
			_ = json.NewEncoder(w).Encode(map[string]any{"items": []any{}})
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"items": []any{}})
	}))
	defer srv.Close()

	dir := setupTestToken(t)
	client := redirectClient(calendarBaseURL, srv.URL)
	events, err := listUpcomingEventsWithClient(context.Background(), dir, 10, client)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(events) != 0 {
		t.Errorf("got %d events, want 0", len(events))
	}
}

func TestListUpcomingEventsWithClient_PartialFailure(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.Contains(r.URL.Path, "calendarList"):
			_ = json.NewEncoder(w).Encode(map[string]any{
				"items": []calendarListEntry{
					{ID: "ok", Summary: "OK", Selected: true},
					{ID: "fail", Summary: "Fail", Selected: true},
				},
			})
		case strings.Contains(r.URL.Path, "ok/events"):
			_ = json.NewEncoder(w).Encode(map[string]any{
				"items": []map[string]any{
					{"id": "e1", "summary": "Visible", "start": map[string]string{"dateTime": "2026-04-01T10:00:00Z"}},
				},
			})
		case strings.Contains(r.URL.Path, "fail/events"):
			http.Error(w, "internal error", http.StatusInternalServerError)
		}
	}))
	defer srv.Close()

	dir := t.TempDir()
	writeToken(t, dir, storedToken{Token: "access", Expiry: time.Now().Add(1 * time.Hour)})
	client := redirectClient(calendarBaseURL, srv.URL)

	events, err := listUpcomingEventsWithClient(context.Background(), dir, 10, client)
	var incomplete *CalendarIncompleteError
	if !errors.As(err, &incomplete) {
		t.Fatalf("expected *CalendarIncompleteError on partial failure, got: %v", err)
	}
	if len(incomplete.Failed) != 1 || incomplete.Failed[0] != "Fail" || !strings.Contains(err.Error(), "500") {
		t.Errorf("incomplete error = %+v (%v), want Failed [Fail] with the 500 cause", incomplete, err)
	}
	if len(events) != 1 {
		t.Errorf("got %d events, want 1 (from the ok calendar)", len(events))
	}
}

func TestCreateEventWithClient_Success(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Errorf("want POST, got %s", r.Method)
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"id": "new-event-id-123"})
	}))
	defer srv.Close()

	dir := t.TempDir()
	writeToken(t, dir, storedToken{Token: "access", Expiry: time.Now().Add(1 * time.Hour)})
	client := redirectClient(calendarBaseURL, srv.URL)

	id, err := createEventWithClient(context.Background(), dir, "primary", "Team Standup", "Daily sync", "2026-04-05T09:00:00Z", "2026-04-05T09:30:00Z", "Room 1", client)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if id != "new-event-id-123" {
		t.Errorf("got id %q, want new-event-id-123", id)
	}
}

func TestCreateEventWithClient_MinimalFields(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]string{"id": "minimal-id"})
	}))
	defer srv.Close()

	dir := t.TempDir()
	writeToken(t, dir, storedToken{Token: "access", Expiry: time.Now().Add(1 * time.Hour)})
	client := redirectClient(calendarBaseURL, srv.URL)

	id, err := createEventWithClient(context.Background(), dir, "", "Meeting", "", "2026-04-05T10:00:00Z", "2026-04-05T11:00:00Z", "", client)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if id != "minimal-id" {
		t.Errorf("got id %q, want minimal-id", id)
	}
}

func TestCreateEventWithClient_InvalidStartTime(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	writeToken(t, dir, storedToken{Token: "access", Expiry: time.Now().Add(1 * time.Hour)})

	_, err := createEventWithClient(context.Background(), dir, "primary", "Bad", "", "not-a-date", "2026-04-05T11:00:00Z", "", http.DefaultClient)
	if err == nil {
		t.Fatal("expected error for invalid start_time")
	}
	if !strings.Contains(err.Error(), "start time") {
		t.Errorf("error should mention 'start time', got: %v", err)
	}
}

func TestCreateEventWithClient_InvalidEndTime(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	writeToken(t, dir, storedToken{Token: "access", Expiry: time.Now().Add(1 * time.Hour)})

	_, err := createEventWithClient(context.Background(), dir, "primary", "Bad", "", "2026-04-05T10:00:00Z", "not-a-date", "", http.DefaultClient)
	if err == nil {
		t.Fatal("expected error for invalid end_time")
	}
	if !strings.Contains(err.Error(), "end time") {
		t.Errorf("error should mention 'end time', got: %v", err)
	}
}

func TestCreateEventWithClient_AuthError(t *testing.T) {
	t.Parallel()
	_, err := createEventWithClient(context.Background(), t.TempDir(), "primary", "Test", "", "2026-04-05T10:00:00Z", "2026-04-05T11:00:00Z", "", http.DefaultClient)
	if err == nil {
		t.Fatal("expected error for missing token")
	}
}

func TestCreateEventWithClient_APIError(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, `{"error":{"message":"forbidden"}}`, http.StatusForbidden)
	}))
	defer srv.Close()

	dir := t.TempDir()
	writeToken(t, dir, storedToken{Token: "access", Expiry: time.Now().Add(1 * time.Hour)})
	client := redirectClient(calendarBaseURL, srv.URL)

	_, err := createEventWithClient(context.Background(), dir, "primary", "Test", "", "2026-04-05T10:00:00Z", "2026-04-05T11:00:00Z", "", client)
	if err == nil {
		t.Fatal("expected error for 403 API response")
	}
	if !strings.Contains(err.Error(), "403") {
		t.Errorf("error should mention 403, got: %v", err)
	}
}

func TestFormatEventsMarkdown_ShowsCalendarName(t *testing.T) {
	t.Parallel()
	events := []CalendarEvent{
		{Summary: "Sprint Review", Start: "2026-03-28T14:00:00-05:00", CalendarName: "Work"},
	}
	out := FormatEventsMarkdown(events)
	if !strings.Contains(out, "[Work]") {
		t.Errorf("expected '[Work]' calendar label in output:\n%s", out)
	}
}

func TestListUpcomingEventsWithClient_Ordering(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name   string
		starts []string
		allDay []bool
		want   []int
	}{
		{name: "mixed offsets", starts: []string{"2026-04-01T09:00:00-05:00", "2026-04-01T09:30:00+02:00"}, want: []int{1, 0}},
		{name: "same offset reversed", starts: []string{"2026-04-01T19:00:00Z", "2026-04-01T09:00:00Z"}, want: []int{1, 0}},
		{name: "equivalent instants stable", starts: []string{"2026-04-01T09:00:00-05:00", "2026-04-01T14:00:00Z", "2026-04-01T16:00:00+02:00"}, want: []int{0, 1, 2}},
		{name: "fractional seconds", starts: []string{"2026-04-01T09:00:00.9Z", "2026-04-01T09:00:00Z", "2026-04-01T09:00:00.12Z"}, want: []int{1, 2, 0}},
		{name: "day boundaries", starts: []string{"2026-04-02T00:30:00+02:00", "2026-04-01T23:00:00Z", "2026-04-01T23:30:00-05:00"}, want: []int{0, 1, 2}},
		{name: "all day midnight ties", starts: []string{"2026-04-02", "2026-04-01T23:59:00Z", "2026-04-02T00:00:00Z", "2026-04-02"}, allDay: []bool{true, false, false, true}, want: []int{1, 0, 2, 3}},
		{name: "invalid starts stable after valid", starts: []string{"bad", "2026-04-02T00:00:00Z", "", "2026-02-30", "2026-04-01", "also-bad"}, allDay: []bool{false, false, true, true, true, false}, want: []int{4, 1, 0, 2, 3, 5}},
		{name: "all invalid stable", starts: []string{"z-invalid", "", "a-invalid"}, allDay: []bool{false, true, false}, want: []int{0, 1, 2}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			originals, items := calendarOrderingFixture(tt.starts, tt.allDay)
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch r.URL.Path {
				case calendarListTestPath:
					_ = json.NewEncoder(w).Encode(map[string]any{"items": []calendarListEntry{{ID: "c0", Summary: "Calendar 0"}, {ID: "c1", Summary: "Calendar 1"}}})
				case "/calendars/c0/events":
					_ = json.NewEncoder(w).Encode(map[string]any{"items": items[0]})
				case "/calendars/c1/events":
					_ = json.NewEncoder(w).Encode(map[string]any{"items": items[1]})
				default:
					t.Errorf("unexpected path: %s", r.URL.Path)
					http.NotFound(w, r)
				}
			}))
			defer srv.Close()
			dir := setupTestToken(t)
			client := redirectClient(calendarBaseURL, srv.URL)
			checkCalendarOrdering(t, dir, client, originals, tt.want)
		})
	}
}

func calendarOrderingFixture(starts []string, allDays []bool) (originals []CalendarEvent, items [2][]map[string]any) {
	originals = make([]CalendarEvent, len(starts))
	// Split consecutive input across two calendars so merge order is explicit.
	split := (len(starts) + 1) / 2
	for i, start := range starts {
		cal := 0
		if i >= split {
			cal = 1
		}
		allDay := len(allDays) > 0 && allDays[i]
		key := "dateTime"
		if allDay {
			key = "date"
		}
		ev := CalendarEvent{ID: fmt.Sprintf("e%d", i), Summary: "Event", Start: start, End: start, Location: "Room", AllDay: allDay, CalendarName: fmt.Sprintf("Calendar %d", cal)}
		originals[i] = ev
		items[cal] = append(items[cal], map[string]any{"id": ev.ID, "summary": ev.Summary, "location": ev.Location, "start": map[string]string{key: start}, "end": map[string]string{key: start}})
	}

	return originals, items
}

func checkCalendarOrdering(t *testing.T, dir string, client *http.Client, originals []CalendarEvent, wantOrder []int) {
	t.Helper()
	for limit := 0; limit <= len(wantOrder)+1; limit++ {
		events, err := listUpcomingEventsWithClient(context.Background(), dir, limit, client)
		if err != nil {
			t.Fatalf("limit %d: %v", limit, err)
		}
		count := min(limit, len(wantOrder))
		if len(events) != count {
			t.Fatalf("limit %d: got %d events, want %d", limit, len(events), count)
		}
		for i, event := range events {
			if want := originals[wantOrder[i]]; event != want {
				t.Errorf("limit %d event %d: got %+v, want %+v", limit, i, event, want)
			}
		}
	}
}

const (
	calendarListTestPath = "/users/me/calendarList"
	calendarTestDate     = "2026-04-01"
	calendarTestCancel   = "cancel"
)

//nolint:gocognit,cyclop // Offline pagination matrix keeps request invariants beside response assertions.
func TestCalendarPagination(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name  string
		pages []string
		limit int
		want  []string
	}{
		{"empty and short pages", []string{`{"nextPageToken":"TOKEN"}`, `{"items":[{"id":"a","start":{"date":"2026-04-01"}}],"nextPageToken":"last"}`, `{"items":[{"id":"b","start":{"dateTime":"2026-04-02T00:00:00Z"}}]}`}, 3, []string{"a", "b"}},
		{"stop at count", []string{`{"items":[{"id":"a","start":{"date":"2026-04-01"}}],"nextPageToken":"TOKEN"}`}, 1, []string{"a"}},
		{"stable ties and cap", []string{`{"items":[{"id":"a","start":{"date":"2026-04-01"}}],"nextPageToken":"TOKEN"}`, `{"items":[{"id":"b","start":{"dateTime":"2026-04-01T00:00:00Z"}},{"id":"c","start":{"date":"2026-04-01"}}]}`}, 2, []string{"a", "b"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			const opaque = "+ /?=&%"
			calls := 0
			timeMin := ""
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == calendarListTestPath {
					if r.URL.Query().Get("minAccessRole") != "reader" {
						t.Error("missing reader filter")
					}
					_, _ = fmt.Fprint(w, `{"items":[{"id":"a/b+@","summary":"Work"}]}`)
					return
				}
				if r.URL.EscapedPath() != "/calendars/a%2Fb+@/events" {
					t.Errorf("path: %s", r.URL.EscapedPath())
				}
				q := r.URL.Query()
				if r.Header.Get("Authorization") != "Bearer fake" || q.Get("maxResults") != fmt.Sprint(tc.limit) || q.Get("singleEvents") != "true" || q.Get("orderBy") != "startTime" {
					t.Errorf("filters/auth: %v", q)
				}
				if calls == 0 {
					timeMin = q.Get("timeMin")
					if _, err := time.Parse(time.RFC3339, timeMin); err != nil {
						t.Error(err)
					}
				}
				if timeMin != q.Get("timeMin") {
					t.Error("timeMin changed")
				}
				expected := ""
				if calls == 1 {
					expected = opaque
				}
				if calls == 2 {
					expected = "last"
				}
				if q.Get("pageToken") != expected {
					t.Errorf("token: %q want %q", q.Get("pageToken"), expected)
				}
				if calls >= len(tc.pages) {
					t.Error("extra request")
					http.Error(w, "extra", 500)
					return
				}
				page := tc.pages[calls]
				calls++
				_, _ = fmt.Fprint(w, strings.ReplaceAll(page, "TOKEN", opaque))
			}))
			defer srv.Close()
			events, err := listUpcomingEventsWithClient(context.Background(), setupTestToken(t), tc.limit, redirectClient(calendarBaseURL, srv.URL))
			if err != nil {
				t.Fatal(err)
			}
			if calls != len(tc.pages) || len(events) != len(tc.want) {
				t.Fatalf("calls %d, events %+v", calls, events)
			}
			for i, id := range tc.want {
				if events[i].ID != id || events[i].CalendarName != "Work" {
					t.Errorf("event: %+v", events[i])
				}
			}
			if len(events) > 0 && (!events[0].AllDay || events[0].Start != calendarTestDate) {
				t.Errorf("all day fields: %+v", events[0])
			}
		})
	}
}

//nolint:gocognit,cyclop // Offline enumeration matrix checks request sequence and global selection together.
func TestCalendarListPagination(t *testing.T) {
	t.Parallel()
	for _, empty := range []bool{false, true} {
		t.Run(fmt.Sprint(empty), func(t *testing.T) {
			t.Parallel()
			listCalls, eventCalls := 0, 0
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == calendarListTestPath {
					q := r.URL.Query()
					if q.Get("minAccessRole") != "reader" {
						t.Error("reader filter lost")
					}
					listCalls++
					switch listCalls {
					case 1:
						if q.Get("pageToken") != "" {
							t.Error("initial token")
						}
						items := `[{"id":"late"}]`
						if empty {
							items = `[]`
						}
						_, _ = fmt.Fprintf(w, `{"items":%s,"nextPageToken":"+ /?=&%%"}`, items)
					case 2:
						if q.Get("pageToken") != "+ /?=&%" {
							t.Errorf("token %q", q.Get("pageToken"))
						}
						_, _ = fmt.Fprint(w, `{"items":[{"id":"early"}]}`)
					default:
						t.Error("extra list request")
						http.Error(w, "extra", 500)
					}
					return
				}
				eventCalls++
				if r.URL.Query().Get("pageToken") != "" {
					t.Error("token leaked between calendars")
				}
				date := "2026-04-02"
				if strings.Contains(r.URL.Path, "early") {
					date = calendarTestDate
				}
				_, _ = fmt.Fprintf(w, `{"items":[{"id":%q,"start":{"date":%q}}]}`, date, date)
			}))
			defer srv.Close()
			events, err := listUpcomingEventsWithClient(context.Background(), setupTestToken(t), 1, redirectClient(calendarBaseURL, srv.URL))
			if err != nil || len(events) != 1 || events[0].ID != calendarTestDate {
				t.Fatalf("events %+v err %v", events, err)
			}
			wantCalls := 2
			if empty {
				wantCalls = 1
			}
			if listCalls != 2 || eventCalls != wantCalls {
				t.Errorf("calls list=%d events=%d", listCalls, eventCalls)
			}
		})
	}
}

//nolint:gocognit,cyclop // Failure matrix verifies transport sequencing and partial-result policy together.
func TestCalendarLaterPageFailures(t *testing.T) {
	t.Parallel()
	for _, endpoint := range []string{"list", "events"} {
		for _, failure := range []string{"http", "json", calendarTestCancel} {
			t.Run(endpoint+"/"+failure, func(t *testing.T) {
				t.Parallel()
				ctx, cancel := context.WithCancel(context.Background())
				defer cancel()
				failedCalls := 0
				srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					isList := r.URL.Path == calendarListTestPath
					if isList && endpoint == "events" {
						_, _ = fmt.Fprint(w, `{"items":[{"id":"healthy"},{"id":"broken"},{"id":"after"}]}`)
						return
					}
					if !isList && !strings.Contains(r.URL.Path, "broken") {
						if strings.Contains(r.URL.Path, "after") && failure == calendarTestCancel {
							t.Error("request after cancellation")
						}
						_, _ = fmt.Fprint(w, `{"items":[{"id":"healthy","start":{"date":"2026-04-01"}}]}`)
						return
					}
					failedCalls++
					if failedCalls == 1 {
						items := `[{"id":"broken"}]`
						if !isList {
							items = `[{"id":"partial","start":{"date":"2026-04-01"}}]`
						}
						_, _ = fmt.Fprintf(w, `{"items":%s,"nextPageToken":"next"}`, items)
						return
					}
					if failedCalls > 2 {
						t.Error("extra failure request")
					}
					switch failure {
					case "http":
						http.Error(w, "failed", http.StatusForbidden)
					case "json":
						_, _ = fmt.Fprint(w, `{`)
					case calendarTestCancel:
						cancel()
						<-r.Context().Done()
					}
				}))
				defer srv.Close()
				events, err := listUpcomingEventsWithClient(ctx, setupTestToken(t), 3, redirectClient(calendarBaseURL, srv.URL))
				if failedCalls != 2 {
					t.Errorf("failed calls %d", failedCalls)
				}
				switch {
				case endpoint == "list":
					if err == nil || !strings.Contains(err.Error(), "calendar list") || events != nil {
						t.Fatalf("events %+v err %v", events, err)
					}
				case failure == calendarTestCancel:
					// Events gathered before cancellation must not be presented as a result.
					var incomplete *CalendarIncompleteError
					if !errors.Is(err, context.Canceled) || errors.As(err, &incomplete) || events != nil {
						t.Fatalf("events %+v err %v, want nil events and cancellation", events, err)
					}
				default:
					var incomplete *CalendarIncompleteError
					if !errors.As(err, &incomplete) || len(incomplete.Failed) != 1 || incomplete.Failed[0] != "broken" || len(events) != 2 {
						t.Fatalf("events %+v err %v, want 2 healthy events and broken reported", events, err)
					}
					for _, ev := range events {
						if ev.ID != "healthy" {
							t.Errorf("partial event leaked: %+v", ev)
						}
					}
				}
			})
		}
	}
}

const calendarTestListEndpoint = "list"

//nolint:gocognit,cyclop // Cycle matrix covers both endpoints with a self-terminating fixture.
func TestCalendarRepeatedContinuationToken(t *testing.T) {
	t.Parallel()
	const hardStop = 8
	cases := []struct {
		name      string
		tokens    []string
		items     bool
		maxCalls  int
		wantOK    bool
		onlyEvent bool
		max       int
	}{
		{name: "identical", tokens: []string{"A", "A"}, items: true, maxCalls: 3, max: 5},
		{name: "alternating", tokens: []string{"A", "B", "A"}, items: true, maxCalls: 4, max: 5},
		{name: "after unique prefix", tokens: []string{"U", "A", "A"}, items: true, maxCalls: 4, max: 5},
		{name: "empty pages", tokens: []string{"A", "A"}, items: false, maxCalls: 3, max: 5},
		{name: "cap before repeat", tokens: []string{"A", "A"}, items: true, maxCalls: 1, wantOK: true, onlyEvent: true, max: 1},
	}
	for _, endpoint := range []string{calendarTestListEndpoint, "events"} {
		for _, tc := range cases {
			if endpoint == calendarTestListEndpoint && tc.onlyEvent {
				continue
			}
			t.Run(endpoint+"/"+tc.name, func(t *testing.T) {
				t.Parallel()
				var calls atomic.Int32
				srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
					n := int(calls.Add(1))
					if n > hardStop {
						http.Error(w, "runaway", http.StatusInternalServerError)
						return
					}
					tok := tc.tokens[len(tc.tokens)-1]
					if n <= len(tc.tokens) {
						tok = tc.tokens[n-1]
					}
					items := `[]`
					if tc.items {
						items = fmt.Sprintf(`[{"id":"i%d","start":{"date":"2026-04-01"}}]`, n)
					}
					_, _ = fmt.Fprintf(w, `{"items":%s,"nextPageToken":%q}`, items, tok)
				}))
				defer srv.Close()
				client := redirectClient(calendarBaseURL, srv.URL)
				var err error
				var got int
				if endpoint == calendarTestListEndpoint {
					var cals []calendarListEntry
					cals, err = listCalendarsWithClient(context.Background(), "tok", client)
					got = len(cals)
				} else {
					var evs []CalendarEvent
					evs, err = listCalendarEventsWithClient(context.Background(), "tok", calendarListEntry{ID: "cal"}, url.Values{}, tc.max, client)
					got = len(evs)
				}
				if int(calls.Load()) > tc.maxCalls {
					t.Errorf("requests %d exceed bound %d", calls.Load(), tc.maxCalls)
				}
				if tc.wantOK {
					if err != nil || got == 0 {
						t.Fatalf("want success, got %d err %v", got, err)
					}
					return
				}
				if !errors.Is(err, errCalendarRepeatedPageToken) || got != 0 {
					t.Fatalf("got %d err %v", got, err)
				}
				if want := "calendar " + endpoint; !strings.Contains(err.Error(), want) {
					t.Errorf("error %q lacks %q", err, want)
				}
			})
		}
	}
}

// calendarFaultTransport simulates a per-request client timeout while the caller's ctx stays live.
type calendarFaultTransport struct{ next http.RoundTripper }

func (f calendarFaultTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	if strings.Contains(r.URL.Path, "/timeout") {
		return nil, fmt.Errorf("client timeout: %w", context.DeadlineExceeded)
	}
	return f.next.RoundTrip(r)
}

// completenessServer serves one calendar per behavior; calendar i is named behavior+i
// and its single event starts later for lower i, so merge order must be restored by sorting.
func completenessServer(t *testing.T, behaviors []string, cancel context.CancelFunc) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == calendarListTestPath {
			items := make([]calendarListEntry, len(behaviors))
			for i, b := range behaviors {
				items[i] = calendarListEntry{ID: fmt.Sprintf("%s%d", b, i), Summary: fmt.Sprintf("%s%d", b, i)}
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"items": items})
			return
		}
		id := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/calendars/"), "/events")
		behavior := strings.TrimRight(id, "0123456789")
		var n int
		_, _ = fmt.Sscan(id[len(behavior):], &n)
		items := []map[string]any{{"id": "ev-" + id, "start": map[string]string{"date": fmt.Sprintf("2026-04-%02d", 20-n)}}}
		switch behavior {
		case "ok":
			_ = json.NewEncoder(w).Encode(map[string]any{"items": items})
		case "blank":
			_ = json.NewEncoder(w).Encode(map[string]any{"items": []any{}})
		case "fail":
			http.Error(w, "backend failure", http.StatusInternalServerError)
		case "repeat":
			_ = json.NewEncoder(w).Encode(map[string]any{"items": items, "nextPageToken": "A"})
		case "abort":
			cancel()
			<-r.Context().Done()
		case "okabort":
			_ = json.NewEncoder(w).Encode(map[string]any{"items": items})
			cancel()
		default:
			t.Errorf("unexpected request for %s", id)
			http.Error(w, "unexpected", http.StatusTeapot)
		}
	}))
}

//nolint:gocognit,cyclop // One matrix keeps the whole completeness contract side by side.
func TestCalendarCompleteness(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name       string
		behaviors  []string
		max        int
		expired    bool
		wantIDs    []string
		wantCause  error    // errors.Is target for a non-partial error
		wantFailed []string // non-nil: want *CalendarIncompleteError naming these calendars
		wantAll    bool     // want the all-calendars-failed error
	}{
		{name: "all healthy", behaviors: []string{"ok", "ok"}, wantIDs: []string{"ev-ok1", "ev-ok0"}},
		{name: "healthy empty", behaviors: []string{"blank", "blank"}},
		{name: "no calendars", behaviors: nil},
		{name: "mixed success", behaviors: []string{"ok", "fail", "ok"}, wantIDs: []string{"ev-ok2", "ev-ok0"}, wantFailed: []string{"fail1"}},
		{name: "mixed success capped", behaviors: []string{"ok", "fail", "ok"}, max: 1, wantIDs: []string{"ev-ok2"}, wantFailed: []string{"fail1"}},
		{name: "partial with no healthy events", behaviors: []string{"blank", "fail"}, wantFailed: []string{"fail1"}},
		{name: "repeated token counts as failure", behaviors: []string{"repeat", "ok"}, wantIDs: []string{"ev-ok1"}, wantFailed: []string{"repeat0"}, wantCause: errCalendarRepeatedPageToken},
		{name: "client timeout is a calendar failure", behaviors: []string{"timeout", "ok"}, wantIDs: []string{"ev-ok1"}, wantFailed: []string{"timeout0"}, wantCause: context.DeadlineExceeded},
		{name: "all calendars failed", behaviors: []string{"fail", "fail"}, wantAll: true},
		{name: "all failed mixed causes", behaviors: []string{"fail", "repeat"}, wantAll: true},
		{name: "canceled mid fetch drops gathered events", behaviors: []string{"ok", "abort", "never"}, wantCause: context.Canceled},
		{name: "canceled after last fetch", behaviors: []string{"ok", "okabort"}, wantCause: context.Canceled},
		{name: "deadline before start", behaviors: []string{"never"}, expired: true, wantCause: context.DeadlineExceeded},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			if tc.expired {
				var stop context.CancelFunc
				ctx, stop = context.WithDeadline(ctx, time.Unix(0, 0))
				defer stop()
			}
			srv := completenessServer(t, tc.behaviors, cancel)
			defer srv.Close()
			client := &http.Client{Transport: calendarFaultTransport{next: redirectClient(calendarBaseURL, srv.URL).Transport}}
			limit := tc.max
			if limit == 0 {
				limit = 10
			}
			events, err := listUpcomingEventsWithClient(ctx, setupTestToken(t), limit, client)

			var incomplete *CalendarIncompleteError
			isPartial := errors.As(err, &incomplete)
			switch {
			case tc.wantFailed != nil:
				if !isPartial || fmt.Sprint(incomplete.Failed) != fmt.Sprint(tc.wantFailed) {
					t.Fatalf("err %v, want incomplete for %v", err, tc.wantFailed)
				}
				if tc.wantCause != nil && !errors.Is(err, tc.wantCause) {
					t.Errorf("err %v lost cause %v", err, tc.wantCause)
				}
			case tc.wantAll:
				if err == nil || isPartial || !strings.Contains(err.Error(), "all 2 calendars failed") {
					t.Fatalf("err %v, want all-failed error", err)
				}
			case tc.wantCause != nil:
				if !errors.Is(err, tc.wantCause) || isPartial {
					t.Fatalf("err %v, want %v", err, tc.wantCause)
				}
			default:
				if err != nil {
					t.Fatalf("unexpected error: %v", err)
				}
			}
			if (tc.wantAll || (tc.wantFailed == nil && tc.wantCause != nil)) && events != nil {
				t.Errorf("failed result returned events %+v", events)
			}
			if len(events) != len(tc.wantIDs) {
				t.Fatalf("events %+v, want %v", events, tc.wantIDs)
			}
			for i, id := range tc.wantIDs {
				if events[i].ID != id {
					t.Errorf("event %d = %q, want %q", i, events[i].ID, id)
				}
			}
		})
	}
}
