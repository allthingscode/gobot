//nolint:testpackage // requires unexported calendar internals for testing
package google

import (
	"context"
	"encoding/json"
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
	if err != nil {
		t.Fatalf("expected nil error on partial failure, got: %v", err)
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
