//nolint:testpackage // requires unexported calendar internals for testing
package google

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
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
	cases := []struct {
		name        string
		items       []map[string]any
		wantCount   int
		wantAllDay  bool
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
			t.Parallel()
			srv := setupCalendarMockServer(t, tc.items)
			t.Cleanup(srv.Close)

			dir := setupTestToken(t)
			client := redirectClient(calendarBaseURL, srv.URL)

			events, err := listUpcomingEventsWithClient(dir, 10, client)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			validateCalendarEvents(t, events, tc.wantCount, tc.wantSummary, tc.wantAllDay)
		})
	}
}

func setupCalendarMockServer(t *testing.T, items []map[string]any) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.Path, "calendarList") {
			if err := json.NewEncoder(w).Encode(map[string]any{
				"items": []map[string]any{
					{"id": "primary", "summary": "My Calendar", "selected": true},
				},
			}); err != nil {
				t.Fatal(err)
			}
			return
		}
		// Per-calendar events endpoint
		if err := json.NewEncoder(w).Encode(map[string]any{"items": items}); err != nil {
			t.Fatal(err)
		}
	}))
}

func setupTestToken(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	writeToken(t, dir, storedToken{
		Token:  "access",
		Expiry: time.Now().Add(1 * time.Hour),
	})
	return dir
}

func validateCalendarEvents(t *testing.T, events []CalendarEvent, wantCount int, wantSummary string, wantAllDay bool) {
	t.Helper()
	if len(events) != wantCount {
		t.Fatalf("want %d events, got %d", wantCount, len(events))
	}
	if wantCount > 0 {
		if events[0].Summary != wantSummary {
			t.Errorf("want summary %q, got %q", wantSummary, events[0].Summary)
		}
		if events[0].AllDay != wantAllDay {
			t.Errorf("want AllDay=%v, got %v", wantAllDay, events[0].AllDay)
		}
	}
}

func TestListUpcomingEventsWithClient_AuthError(t *testing.T) {
	t.Parallel()
	_, err := listUpcomingEventsWithClient(t.TempDir(), 10, http.DefaultClient)
	if err == nil {
		t.Fatal("expected error for missing token file")
	}
}

func TestListUpcomingEventsWithClient_MultipleCalendars(t *testing.T) {
	t.Parallel()
	srv := setupMultipleCalendarsMockServer(t)
	defer srv.Close()

	dir := setupTestToken(t)
	client := redirectClient(calendarBaseURL, srv.URL)

	events, err := listUpcomingEventsWithClient(dir, 10, client)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	validateMultipleCalendarEvents(t, events)
}

func setupMultipleCalendarsMockServer(t *testing.T) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.Path, "calendarList") {
			_ = json.NewEncoder(w).Encode(map[string]any{
				"items": []map[string]any{
					{"id": "cal-a", "summary": "Calendar A", "selected": true},
					{"id": "cal-b", "summary": "Calendar B", "selected": true},
				},
			})
			return
		}
		if strings.Contains(r.URL.Path, "cal-a") {
			_ = json.NewEncoder(w).Encode(map[string]any{
				"items": []map[string]any{
					{
						"id": "a1", "summary": "Event A1",
						"start": map[string]string{"dateTime": "2026-03-28T10:00:00Z"},
						"end":   map[string]string{"dateTime": "2026-03-28T11:00:00Z"},
					},
				},
			})
			return
		}
		if strings.Contains(r.URL.Path, "cal-b") {
			_ = json.NewEncoder(w).Encode(map[string]any{
				"items": []map[string]any{
					{
						"id": "b1", "summary": "Event B1",
						"start": map[string]string{"dateTime": "2026-03-28T09:00:00Z"},
						"end":   map[string]string{"dateTime": "2026-03-28T10:00:00Z"},
					},
				},
			})
			return
		}
	}))
}

func validateMultipleCalendarEvents(t *testing.T, events []CalendarEvent) {
	t.Helper()
	if len(events) != 2 {
		t.Fatalf("want 2 events, got %d", len(events))
	}
	// Sorted by start time: B1 (09:00) then A1 (10:00)
	if events[0].Summary != "Event B1" || events[0].CalendarName != "Calendar B" {
		t.Errorf("want first event 'Event B1' from 'Calendar B', got %q from %q", events[0].Summary, events[0].CalendarName)
	}
	if events[1].Summary != "Event A1" || events[1].CalendarName != "Calendar A" {
		t.Errorf("want second event 'Event A1' from 'Calendar A', got %q from %q", events[1].Summary, events[1].CalendarName)
	}
}

func TestListUpcomingEventsWithClient_UnselectedCalendarIncluded(t *testing.T) {
	t.Parallel()
	var calledA, calledB bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		handleUnselectedCalendarMock(t, w, r, &calledA, &calledB)
	}))
	defer srv.Close()

	dir := setupTestToken(t)
	client := redirectClient(calendarBaseURL, srv.URL)

	_, err := listUpcomingEventsWithClient(dir, 10, client)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !calledA || !calledB {
		t.Errorf("expected both calendars to be called: A=%v, B=%v", calledA, calledB)
	}
}

func handleUnselectedCalendarMock(t *testing.T, w http.ResponseWriter, r *http.Request, calledA, calledB *bool) {
	t.Helper()
	if strings.Contains(r.URL.Path, "calendarList") {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"items": []map[string]any{
				{"id": "cal-a", "summary": "Calendar A", "selected": true},
				{"id": "cal-b", "summary": "Calendar B", "selected": false},
			},
		})
		return
	}
	if strings.Contains(r.URL.Path, "cal-a") {
		*calledA = true
		_ = json.NewEncoder(w).Encode(map[string]any{"items": []any{}})
		return
	}
	if strings.Contains(r.URL.Path, "cal-b") {
		*calledB = true
		_ = json.NewEncoder(w).Encode(map[string]any{"items": []any{}})
		return
	}
}

func TestListUpcomingEventsWithClient_PartialFailure(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.Path, "calendarList") {
			if err := json.NewEncoder(w).Encode(map[string]any{
				"items": []map[string]any{
					{"id": "cal-fail", "summary": "Fail Calendar", "selected": true},
					{"id": "cal-ok", "summary": "OK Calendar", "selected": true},
				},
			}); err != nil {
				t.Fatal(err)
			}
			return
		}
		if strings.Contains(r.URL.Path, "cal-fail") {
			w.WriteHeader(http.StatusForbidden)
			fmt.Fprint(w, `{"error":{"message":"forbidden"}}`)
			return
		}
		if strings.Contains(r.URL.Path, "cal-ok") {
			if err := json.NewEncoder(w).Encode(map[string]any{
				"items": []map[string]any{
					{
						"id": "ok1", "summary": "OK Event",
						"start": map[string]string{"dateTime": "2026-03-28T12:00:00Z"},
						"end":   map[string]string{"dateTime": "2026-03-28T13:00:00Z"},
					},
				},
			}); err != nil {
				t.Fatal(err)
			}
			return
		}
	}))
	defer srv.Close()

	dir := t.TempDir()
	writeToken(t, dir, storedToken{Token: "access", Expiry: time.Now().Add(1 * time.Hour)})
	client := redirectClient(calendarBaseURL, srv.URL)

	events, err := listUpcomingEventsWithClient(dir, 10, client)
	if err != nil {
		t.Fatalf("expected nil error on partial failure, got: %v", err)
	}
	if len(events) != 1 {
		t.Fatalf("want 1 event from OK calendar, got %d", len(events))
	}
	if events[0].Summary != "OK Event" {
		t.Errorf("want summary 'OK Event', got %q", events[0].Summary)
	}
}

func TestCreateEventWithClient_Success(t *testing.T) {
	t.Parallel()
	var gotBody map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := json.NewDecoder(r.Body).Decode(&gotBody); err != nil {
			t.Errorf("decode body: %v", err)
		}
		if err := json.NewEncoder(w).Encode(map[string]string{"id": "evt-abc-123"}); err != nil {
			t.Fatal(err)
		}
	}))
	defer srv.Close()

	dir := t.TempDir()
	writeToken(t, dir, storedToken{Token: "access", Expiry: time.Now().Add(1 * time.Hour)})
	client := redirectClient(calendarBaseURL, srv.URL)

	id, err := createEventWithClient(dir, "primary", "Team Standup", "Daily sync", "2026-04-05T09:00:00Z", "2026-04-05T09:30:00Z", "Room 1", client)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if id != "evt-abc-123" {
		t.Errorf("want id evt-abc-123, got %q", id)
	}
	if gotBody["summary"] != "Team Standup" {
		t.Errorf("want summary 'Team Standup' in body, got %v", gotBody["summary"])
	}
	if gotBody["description"] != "Daily sync" {
		t.Errorf("want description 'Daily sync' in body, got %v", gotBody["description"])
	}
	if gotBody["location"] != "Room 1" {
		t.Errorf("want location 'Room 1' in body, got %v", gotBody["location"])
	}
}

func TestCreateEventWithClient_MinimalFields(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		if _, ok := body["description"]; ok {
			t.Error("description should be absent when empty")
		}
		if _, ok := body["location"]; ok {
			t.Error("location should be absent when empty")
		}
		if err := json.NewEncoder(w).Encode(map[string]string{"id": "evt-min"}); err != nil {
			t.Fatal(err)
		}
	}))
	defer srv.Close()

	dir := t.TempDir()
	writeToken(t, dir, storedToken{Token: "access", Expiry: time.Now().Add(1 * time.Hour)})
	client := redirectClient(calendarBaseURL, srv.URL)

	id, err := createEventWithClient(dir, "", "Meeting", "", "2026-04-05T10:00:00Z", "2026-04-05T11:00:00Z", "", client)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if id != "evt-min" {
		t.Errorf("want id evt-min, got %q", id)
	}
}

func TestCreateEventWithClient_InvalidStartTime(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	writeToken(t, dir, storedToken{Token: "access", Expiry: time.Now().Add(1 * time.Hour)})

	_, err := createEventWithClient(dir, "primary", "Bad", "", "not-a-date", "2026-04-05T11:00:00Z", "", http.DefaultClient)
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

	_, err := createEventWithClient(dir, "primary", "Bad", "", "2026-04-05T10:00:00Z", "not-a-date", "", http.DefaultClient)
	if err == nil {
		t.Fatal("expected error for invalid end_time")
	}
	if !strings.Contains(err.Error(), "end time") {
		t.Errorf("error should mention 'end time', got: %v", err)
	}
}

func TestCreateEventWithClient_AuthError(t *testing.T) {
	t.Parallel()
	_, err := createEventWithClient(t.TempDir(), "primary", "Test", "", "2026-04-05T10:00:00Z", "2026-04-05T11:00:00Z", "", http.DefaultClient)
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

	_, err := createEventWithClient(dir, "primary", "Test", "", "2026-04-05T10:00:00Z", "2026-04-05T11:00:00Z", "", client)
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
