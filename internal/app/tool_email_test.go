//nolint:testpackage // intentionally uses unexported helpers from main package
package app

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/integrations/google"
)

type fakeGmailService struct {
	mu             sync.Mutex
	summaries      []google.MessageSummary
	messages       map[string]*google.Message
	searchErr      error
	getErr         error
	getErrByID     map[string]error
	seenQuery      string
	seenMaxResults int
	seenMessageID  string
}

func (f *fakeGmailService) SearchMessages(_ context.Context, query string, maxResults int) ([]google.MessageSummary, error) {
	f.mu.Lock()
	defer f.mu.Unlock()

	f.seenQuery = query
	f.seenMaxResults = maxResults
	if f.searchErr != nil {
		return nil, f.searchErr
	}
	return f.summaries, nil
}

func (f *fakeGmailService) GetMessage(_ context.Context, id string) (*google.Message, error) {
	f.mu.Lock()
	defer f.mu.Unlock()

	f.seenMessageID = id
	if f.getErrByID != nil {
		if err := f.getErrByID[id]; err != nil {
			return nil, err
		}
	}
	if f.getErr != nil {
		return nil, f.getErr
	}
	return f.messages[id], nil
}

func (f *fakeGmailService) observedSearch() (query string, maxResults int) {
	f.mu.Lock()
	defer f.mu.Unlock()

	return f.seenQuery, f.seenMaxResults
}

func (f *fakeGmailService) observedMessageID() string {
	f.mu.Lock()
	defer f.mu.Unlock()

	return f.seenMessageID
}

func fakeGmailServiceFactory(t *testing.T, svc gmailService) gmailServiceFactory {
	t.Helper()

	return func(context.Context, string) (gmailService, error) {
		return svc, nil
	}
}

func gmailTestMessage(id, from, to, date, subject, snippet, body string) *google.Message {
	return &google.Message{
		ID:      id,
		Snippet: snippet,
		Payload: &google.Payload{
			Headers: []google.Header{
				{Name: "From", Value: from},
				{Name: "To", Value: to},
				{Name: "Date", Value: date},
				{Name: "Subject", Value: subject},
			},
			Body: &google.Body{Data: base64.URLEncoding.EncodeToString([]byte(body))},
		},
	}
}

func TestSendEmailTool_Basic(t *testing.T) {
	t.Parallel()

	tool := newSendEmailTool("/tmp/secrets", "/tmp/storage", "user@example.com", nil, nil, nil)

	t.Run("Name", func(t *testing.T) {
		t.Parallel()
		if tool.Name() != sendEmailToolName {
			t.Errorf("Name() = %q, want %q", tool.Name(), sendEmailToolName)
		}
	})

	t.Run("Declaration", func(t *testing.T) {
		t.Parallel()
		decl := tool.Declaration()

		if decl.Name != sendEmailToolName {
			t.Errorf("Declaration.Name = %q, want %q", decl.Name, sendEmailToolName)
		}

		props, _ := decl.Parameters["properties"].(map[string]any)
		if _, ok := props["to"]; ok {
			t.Error("Declaration.Parameters.Properties must NOT contain \"to\" (security constraint)")
		}

		reqs, _ := decl.Parameters["required"].([]string)
		requiredSet := make(map[string]bool, len(reqs))
		for _, r := range reqs {
			requiredSet[r] = true
		}
		for _, req := range []string{"subject", "body"} {
			if !requiredSet[req] {
				t.Errorf("Required must contain %q", req)
			}
		}
	})
}

func TestSendEmailTool_Execute_Validation(t *testing.T) {
	t.Parallel()

	tool := newSendEmailTool(t.TempDir(), t.TempDir(), "user@example.com", nil, nil, nil)

	tests := []struct {
		name   string
		args   map[string]any
		errSub string
	}{
		{"missing subject key", map[string]any{"body": "Hello"}, "subject is required"},
		{"empty subject string", map[string]any{"subject": "", "body": "Hello"}, "subject is required"},
		{"non-string subject", map[string]any{"subject": 42, "body": "Hello"}, "subject is required"},
		{"missing body key", map[string]any{"subject": "Hello"}, "body is required"},
		{"empty body string", map[string]any{"subject": "Hello", "body": ""}, "body is required"},
		{"non-string body", map[string]any{"subject": "Hello", "body": 99.9}, "body is required"},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			_, err := tool.Execute(context.Background(), "test-session", "", tt.args)
			if err == nil {
				t.Fatal("Execute() expected error, got nil")
			}
			if !strings.Contains(err.Error(), tt.errSub) {
				t.Errorf("error %q does not contain %q", err.Error(), tt.errSub)
			}
		})
	}
}

func TestSendEmailTool_Execute_AuthFailure(t *testing.T) {
	t.Parallel()

	// An empty secretsRoot has no token.json, so google.NewService will fail.
	tool := newSendEmailTool(t.TempDir(), t.TempDir(), "user@example.com", nil, nil, nil)
	_, err := tool.Execute(context.Background(), "test-session", "", map[string]any{
		"subject": "Test subject",
		"body":    "Test body",
	})
	if err == nil {
		t.Fatal("Execute() expected error for missing token, got nil")
	}
	if !strings.Contains(err.Error(), "auth") && !strings.Contains(err.Error(), "token.json") {
		t.Errorf("error %q should mention auth or token.json failure", err.Error())
	}
	_ = google.ErrNeedsReauth // ensure the import is used
}

func TestGmailTools_Declarations(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		tool     Tool
		wantName string
		wantProp string
	}{
		{
			name:     "Search",
			tool:     newSearchGmailTool(t.TempDir(), nil),
			wantName: searchGmailToolName,
			wantProp: "query",
		},
		{
			name:     "Read",
			tool:     newReadGmailTool(t.TempDir(), nil),
			wantName: readGmailToolName,
			wantProp: "message_id",
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			decl := tt.tool.Declaration()
			if decl.Name != tt.wantName {
				t.Errorf("Name = %q, want %q", decl.Name, tt.wantName)
			}
			props, _ := decl.Parameters["properties"].(map[string]any)
			if _, ok := props[tt.wantProp]; !ok {
				t.Errorf("Missing %q property", tt.wantProp)
			}
		})
	}
}

func TestGmailTools_Execute_Validation(t *testing.T) {
	t.Parallel()

	tmp := t.TempDir()
	// Create a dummy token.json to avoid auth errors during arg validation
	// for tests that expect an arg validation error.
	tok := map[string]any{
		"token":  "dummy",
		"expiry": time.Now().Add(1 * time.Hour).Format(time.RFC3339),
	}
	tokData, _ := json.Marshal(tok)
	_ = os.WriteFile(filepath.Join(tmp, "token.json"), tokData, 0o600)

	tests := []struct {
		name   string
		tool   Tool
		args   map[string]any
		errSub string
	}{
		{
			name:   "SearchMissingQuery",
			tool:   newSearchGmailTool(tmp, nil),
			args:   map[string]any{},
			errSub: "query is required",
		},
		{
			name:   "ReadMissingID",
			tool:   newReadGmailTool(tmp, nil),
			args:   map[string]any{},
			errSub: "message_id is required",
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			_, err := tt.tool.Execute(context.Background(), "s", "", tt.args)
			if err == nil {
				t.Error("Expected error for missing required arg")
			}
			if !strings.Contains(err.Error(), tt.errSub) {
				t.Errorf("error %q does not contain %q", err.Error(), tt.errSub)
			}
		})
	}
}

func TestSearchGmailTool_Execute_Success(t *testing.T) {
	t.Parallel()

	fake := &fakeGmailService{
		summaries: []google.MessageSummary{{ID: "msg-1"}},
		messages: map[string]*google.Message{
			"msg-1": gmailTestMessage("msg-1", "alice@example.com", "user@example.com", "Tue, 14 Jul 2026 09:00:00 -0500", "Quarterly update", "Snippet text", "Body text"),
		},
	}
	tool := newSearchGmailTool(t.TempDir(), nil)
	tool.serviceFactory = fakeGmailServiceFactory(t, fake)

	got, err := tool.Execute(context.Background(), "session", "user", map[string]any{
		"query":       "from:alice@example.com",
		"max_results": float64(7),
	})
	if err != nil {
		t.Fatalf("Execute() error = %v", err)
	}
	seenQuery, seenMaxResults := fake.observedSearch()
	if seenQuery != "from:alice@example.com" {
		t.Errorf("query = %q, want from:alice@example.com", seenQuery)
	}
	if seenMaxResults != 7 {
		t.Errorf("maxResults = %d, want 7", seenMaxResults)
	}
	for _, want := range []string{
		"Found 1 messages:",
		"- **ID**: msg-1",
		"**From**: alice@example.com",
		"**Subject**: Quarterly update",
		"**Snippet**: Snippet text",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("output missing %q:\n%s", want, got)
		}
	}
}

func TestSearchGmailTool_Execute_EmptyResults(t *testing.T) {
	t.Parallel()

	tool := newSearchGmailTool(t.TempDir(), nil)
	tool.serviceFactory = fakeGmailServiceFactory(t, &fakeGmailService{})

	got, err := tool.Execute(context.Background(), "session", "user", map[string]any{
		"query": "is:unread",
	})
	if err != nil {
		t.Fatalf("Execute() error = %v", err)
	}
	if got != "No messages found matching the query." {
		t.Errorf("output = %q, want empty-results message", got)
	}
}

func TestSearchGmailTool_Execute_SearchFailure(t *testing.T) {
	t.Parallel()

	tool := newSearchGmailTool(t.TempDir(), nil)
	tool.serviceFactory = fakeGmailServiceFactory(t, &fakeGmailService{searchErr: errors.New("gmail backend down")})

	_, err := tool.Execute(context.Background(), "session", "user", map[string]any{
		"query": "subject:report",
	})
	if err == nil {
		t.Fatal("Execute() expected error, got nil")
	}
	for _, want := range []string{"search_gmail", "search messages", "gmail backend down"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q missing %q", err.Error(), want)
		}
	}
}

func TestSearchGmailTool_Execute_PartialDetailFailure(t *testing.T) {
	t.Parallel()

	fake := &fakeGmailService{
		summaries: []google.MessageSummary{{ID: "msg-ok"}, {ID: "msg-fail"}},
		messages: map[string]*google.Message{
			"msg-ok": gmailTestMessage("msg-ok", "alice@example.com", "user@example.com", "Tue, 14 Jul 2026 09:00:00 -0500", "Good message", "Successful snippet", "Body text"),
		},
		getErrByID: map[string]error{"msg-fail": errors.New("not found")},
	}
	tool := newSearchGmailTool(t.TempDir(), nil)
	tool.serviceFactory = fakeGmailServiceFactory(t, fake)

	got, err := tool.Execute(context.Background(), "session", "user", map[string]any{
		"query": "newer_than:7d",
	})
	if err != nil {
		t.Fatalf("Execute() error = %v", err)
	}
	for _, want := range []string{
		"- **ID**: msg-ok",
		"**From**: alice@example.com",
		"**Subject**: Good message",
		"**Snippet**: Successful snippet",
		"- ID: msg-fail (Error loading details)",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("output missing %q:\n%s", want, got)
		}
	}
}

func TestReadGmailTool_Execute_Success(t *testing.T) {
	t.Parallel()

	fake := &fakeGmailService{
		messages: map[string]*google.Message{
			"msg-1": gmailTestMessage("msg-1", "alice@example.com", "user@example.com", "Tue, 14 Jul 2026 09:00:00 -0500", "Quarterly update", "Snippet text", "Decoded body text"),
		},
	}
	tool := newReadGmailTool(t.TempDir(), nil)
	tool.serviceFactory = fakeGmailServiceFactory(t, fake)

	got, err := tool.Execute(context.Background(), "session", "user", map[string]any{
		"message_id": "msg-1",
	})
	if err != nil {
		t.Fatalf("Execute() error = %v", err)
	}
	if seenMessageID := fake.observedMessageID(); seenMessageID != "msg-1" {
		t.Errorf("messageID = %q, want msg-1", seenMessageID)
	}
	for _, want := range []string{
		"### Email Details (ID: msg-1)",
		"**From**: alice@example.com",
		"**To**: user@example.com",
		"**Date**: Tue, 14 Jul 2026 09:00:00 -0500",
		"**Subject**: Quarterly update",
		"Decoded body text",
		"---",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("output missing %q:\n%s", want, got)
		}
	}
}

func TestReadGmailTool_Execute_GetMessageFailure(t *testing.T) {
	t.Parallel()

	tool := newReadGmailTool(t.TempDir(), nil)
	tool.serviceFactory = fakeGmailServiceFactory(t, &fakeGmailService{getErr: errors.New("gmail backend down")})

	_, err := tool.Execute(context.Background(), "session", "user", map[string]any{
		"message_id": "msg-1",
	})
	if err == nil {
		t.Fatal("Execute() expected error, got nil")
	}
	for _, want := range []string{"read_gmail", "get message", "gmail backend down"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q missing %q", err.Error(), want)
		}
	}
}
