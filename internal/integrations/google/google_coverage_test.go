package google

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// ── Tasks ────────────────────────────────────────────────────────────────────

func TestListTasksWithClient_AuthError(t *testing.T) {
	t.Parallel()
	_, err := listTasksWithClient(context.Background(), t.TempDir(), "@default", nil)
	if err == nil || !strings.Contains(err.Error(), "tasks auth") {
		t.Errorf("expected tasks auth error, got %v", err)
	}
}

func TestListTasksWithClient_Success(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"items": []map[string]any{
				{"id": "t1", "title": "Do thing", "status": "needsAction"},
				{"id": "t2", "title": "Done already", "status": "completed"},
			},
		})
	}))
	defer srv.Close()

	dir := t.TempDir()
	writeToken(t, dir, storedToken{Token: "tok", Expiry: time.Now().Add(time.Hour)})
	tasks, err := listTasksWithClient(context.Background(), dir, "@default", redirectClient(tasksBaseURL, srv.URL))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(tasks) != 1 || tasks[0].ID != "t1" {
		t.Errorf("expected 1 incomplete task, got %+v", tasks)
	}
}

func TestCreateTaskWithClient_Success(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]string{"id": "created-id"})
	}))
	defer srv.Close()

	dir := t.TempDir()
	writeToken(t, dir, storedToken{Token: "tok", Expiry: time.Now().Add(time.Hour)})
	id, err := createTaskWithClient(context.Background(), dir, "", "My Task", "notes", redirectClient(tasksBaseURL, srv.URL))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if id != "created-id" {
		t.Errorf("expected created-id, got %q", id)
	}
}

func TestCompleteTaskWithClient_Success(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]string{})
	}))
	defer srv.Close()

	dir := t.TempDir()
	writeToken(t, dir, storedToken{Token: "tok", Expiry: time.Now().Add(time.Hour)})
	err := completeTaskWithClient(context.Background(), dir, "", "task-id", redirectClient(tasksBaseURL, srv.URL))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestUpdateTaskWithClient_NoFields(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	writeToken(t, dir, storedToken{Token: "tok", Expiry: time.Now().Add(time.Hour)})
	err := updateTaskWithClient(context.Background(), dir, "", "task-id", "", "", "", &http.Client{})
	if err == nil || !strings.Contains(err.Error(), "at least one field") {
		t.Errorf("expected 'at least one field' error, got %v", err)
	}
}

func TestUpdateTaskWithClient_Success(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]string{})
	}))
	defer srv.Close()

	dir := t.TempDir()
	writeToken(t, dir, storedToken{Token: "tok", Expiry: time.Now().Add(time.Hour)})
	err := updateTaskWithClient(context.Background(), dir, "", "task-id", "new title", "", "", redirectClient(tasksBaseURL, srv.URL))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

// ── Tasks thin wrappers (no token) ───────────────────────────────────────────

func TestListTasks_NoToken(t *testing.T) {
	t.Parallel()
	_, err := ListTasks(context.Background(), t.TempDir(), "@default")
	if err == nil {
		t.Error("expected auth error without token")
	}
}

func TestCreateTask_NoToken(t *testing.T) {
	t.Parallel()
	_, err := CreateTask(context.Background(), t.TempDir(), "", "Task Title", "notes")
	if err == nil {
		t.Error("expected auth error without token")
	}
}

func TestCompleteTask_NoToken(t *testing.T) {
	t.Parallel()
	err := CompleteTask(context.Background(), t.TempDir(), "", "task-id")
	if err == nil {
		t.Error("expected auth error without token")
	}
}

// ── formatDueDate ─────────────────────────────────────────────────────────────

func TestFormatDueDate(t *testing.T) {
	t.Parallel()
	if got := formatDueDate("2024-01-01T00:00:00Z"); got != "2024-01-01" {
		t.Errorf("expected '2024-01-01', got %q", got)
	}
	if got := formatDueDate("short"); got != "short" {
		t.Errorf("expected 'short', got %q", got)
	}
	if got := formatDueDate(""); got != "" {
		t.Errorf("expected empty string, got %q", got)
	}
}

// ── Search ───────────────────────────────────────────────────────────────────

func TestNewSearchService_Defaults(t *testing.T) {
	t.Parallel()
	svc := NewSearchService()
	if svc.BaseURL != DefaultBaseURL {
		t.Errorf("expected default base URL, got %q", svc.BaseURL)
	}
	if svc.HTTPClient == nil {
		t.Error("expected non-nil HTTP client")
	}
}

func TestExecuteSearch_MissingCreds(t *testing.T) {
	t.Parallel()
	_, err := ExecuteSearch(context.Background(), "", "cx", "query")
	if err == nil || !strings.Contains(err.Error(), "apiKey and customCx are required") {
		t.Errorf("expected missing creds error, got %v", err)
	}
}

// ── Gmail: GetHeader ─────────────────────────────────────────────────────────

func TestGetHeader_NilPayload(t *testing.T) {
	t.Parallel()
	m := &Message{}
	if got := m.GetHeader("Subject"); got != "" {
		t.Errorf("expected empty string for nil payload, got %q", got)
	}
}

func TestGetHeader_Found(t *testing.T) {
	t.Parallel()
	m := &Message{
		Payload: &Payload{
			Headers: []Header{
				{Name: "Subject", Value: "Hello World"},
				{Name: "From", Value: "alice@example.com"},
			},
		},
	}
	if got := m.GetHeader("subject"); got != "Hello World" {
		t.Errorf("expected 'Hello World', got %q", got)
	}
}

func TestGetHeader_NotFound(t *testing.T) {
	t.Parallel()
	m := &Message{Payload: &Payload{Headers: []Header{{Name: "X-Custom", Value: "val"}}}}
	if got := m.GetHeader("Missing"); got != "" {
		t.Errorf("expected empty string, got %q", got)
	}
}

// ── resolveClientCredentials ─────────────────────────────────────────────────

func TestResolveClientCredentials_FileSuccess(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	cs := map[string]any{
		"installed": map[string]any{ //nolint:gosec // G101: fake test credentials only
			"client_id":     "fake-client-id",
			"client_secret": "fake-client-secret",
		},
	}
	data, _ := json.Marshal(cs)
	_ = os.WriteFile(filepath.Join(dir, "client_secrets.json"), data, 0o600)

	clientID, clientSecret, err := resolveClientCredentials(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if clientID != "fake-client-id" || clientSecret != "fake-client-secret" { //nolint:gosec // G101: fake test credentials
		t.Errorf("unexpected credentials: %q / %q", clientID, clientSecret)
	}
}

// ── Calendar thin wrappers ────────────────────────────────────────────────────

func TestListUpcomingEvents_NoToken(t *testing.T) {
	t.Parallel()
	_, err := ListUpcomingEvents(context.Background(), t.TempDir(), 10)
	if err == nil {
		t.Error("expected auth error without token")
	}
}

func TestCreateEvent_NoToken(t *testing.T) {
	t.Parallel()
	_, err := CreateEvent(context.Background(), t.TempDir(), "", "Meeting", "", "2024-01-01T10:00:00Z", "2024-01-01T11:00:00Z", "Office")
	if err == nil {
		t.Error("expected auth error without token")
	}
}

// ── apiGet non-401 error ──────────────────────────────────────────────────────

func TestAPIGet_500Error(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte("server error"))
	}))
	defer srv.Close()

	err := apiGet(context.Background(), "tok", srv.URL, srv.Client(), &struct{}{})
	if err == nil || !strings.Contains(err.Error(), "500") {
		t.Errorf("expected 500 error, got %v", err)
	}
}

func TestDoGoogleRequest_Success(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{}`))
	}))
	defer srv.Close()

	err := doGoogleRequest(context.Background(), http.MethodPost, "tok", srv.URL, map[string]string{"k": "v"}, srv.Client(), &struct{}{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestGetMessage_Success(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(&Message{
			Payload: &Payload{Headers: []Header{{Name: "Subject", Value: "Hello"}}},
		})
	}))
	defer srv.Close()

	svc := &Service{baseURL: srv.URL, accessToken: "tok", httpClient: srv.Client()}
	msg, err := svc.GetMessage(context.Background(), "msg-id")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if msg.GetHeader("subject") != "Hello" {
		t.Errorf("expected 'Hello', got %q", msg.GetHeader("subject"))
	}
}

func TestExtractBody_WithBodyData(t *testing.T) {
	t.Parallel()
	encoded := base64.URLEncoding.EncodeToString([]byte("hello world"))
	m := &Message{
		Payload: &Payload{
			Body: &Body{Data: encoded},
		},
	}
	if got := m.ExtractBody(); got != "hello world" {
		t.Errorf("expected 'hello world', got %q", got)
	}
}

func TestResolveClientCredentials_InvalidJSON(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "client_secrets.json"), []byte(`{not valid json`), 0o600)
	_, _, err := resolveClientCredentials(dir)
	if err == nil || !strings.Contains(err.Error(), "invalid client_secrets.json") {
		t.Errorf("expected invalid JSON error, got %v", err)
	}
}

// ── persistToken ──────────────────────────────────────────────────────────────

func TestPersistToken(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	tok := &storedToken{
		Token:        "access-token",
		RefreshToken: "refresh-token",
		Expiry:       time.Now().Add(time.Hour),
	}
	if err := persistToken(dir, tok); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if _, err := os.Stat(GoogleTokenPath(dir)); err != nil {
		t.Errorf("expected google_token.json to exist: %v", err)
	}
}

// ── ExtractBody additional paths ──────────────────────────────────────────────

func TestExtractBody_WithPlainTextPart(t *testing.T) {
	t.Parallel()
	encoded := base64.URLEncoding.EncodeToString([]byte("plain text content"))
	m := &Message{
		Payload: &Payload{
			Parts: []Part{
				{MimeType: "text/plain", Body: &Body{Data: encoded}},
			},
		},
	}
	if got := m.ExtractBody(); got != "plain text content" {
		t.Errorf("expected 'plain text content', got %q", got)
	}
}

func TestExtractBody_WithMultipart(t *testing.T) {
	t.Parallel()
	encoded := base64.URLEncoding.EncodeToString([]byte("nested content"))
	m := &Message{
		Payload: &Payload{
			Parts: []Part{
				{
					MimeType: "multipart/alternative",
					Parts:    []Part{{MimeType: "text/plain", Body: &Body{Data: encoded}}},
				},
			},
		},
	}
	if got := m.ExtractBody(); got != "nested content" {
		t.Errorf("expected 'nested content', got %q", got)
	}
}

func TestExtractBody_InvalidBase64(t *testing.T) {
	t.Parallel()
	m := &Message{
		Payload: &Payload{
			Body: &Body{Data: "not-valid-base64!!!"},
		},
	}
	if got := m.ExtractBody(); got != "" {
		t.Errorf("expected empty string for invalid base64, got %q", got)
	}
}

func TestExtractBody_NilPayload(t *testing.T) {
	t.Parallel()
	m := &Message{}
	if got := m.ExtractBody(); got != "" {
		t.Errorf("expected empty string for nil payload, got %q", got)
	}
}

// ── doGoogleRequest additional error paths ────────────────────────────────────

func TestDoGoogleRequest_DecodeError(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`not valid json`))
	}))
	defer srv.Close()

	var dest map[string]string
	err := doGoogleRequest(context.Background(), http.MethodPost, "tok", srv.URL, map[string]string{"k": "v"}, srv.Client(), &dest)
	if err == nil || !strings.Contains(err.Error(), "decode response") {
		t.Errorf("expected decode response error, got %v", err)
	}
}

func TestDoGoogleRequest_ClientError(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	err := doGoogleRequest(ctx, http.MethodPost, "tok", "http://127.0.0.1:9", map[string]string{}, &http.Client{Timeout: time.Second}, &struct{}{})
	if err == nil {
		t.Error("expected error for cancelled context")
	}
}

// ── NewService expired-no-refresh path ────────────────────────────────────────

func TestNewService_ExpiredNoRefreshToken(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	tok := storedToken{
		Token:  "old-token",
		Expiry: time.Now().Add(-time.Hour),
	}
	data, _ := json.Marshal(tok) //nolint:gosec // G117: storedToken.RefreshToken is intentionally empty in test
	_ = os.WriteFile(filepath.Join(dir, "token.json"), data, 0o600)

	_, err := NewService(context.Background(), dir)
	if err == nil || !errors.Is(err, ErrNeedsReauth) {
		t.Errorf("expected ErrNeedsReauth, got %v", err)
	}
}

// ── GetMessage error paths ────────────────────────────────────────────────────

func TestGetMessage_BadRequest(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`bad request`))
	}))
	defer srv.Close()

	svc := &Service{baseURL: srv.URL, accessToken: "tok", httpClient: srv.Client()}
	_, err := svc.GetMessage(context.Background(), "msg-id")
	if err == nil {
		t.Error("expected error for 400 response")
	}
}

func TestGetMessage_ContextCancelled(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	svc := &Service{baseURL: "http://127.0.0.1:0", accessToken: "tok", httpClient: &http.Client{Timeout: time.Second}}
	_, err := svc.GetMessage(ctx, "msg-id")
	if err == nil {
		t.Error("expected error for cancelled context")
	}
}

// ── NewService error paths ────────────────────────────────────────────────────

func TestNewService_NoTokenFile(t *testing.T) {
	t.Parallel()
	_, err := NewService(context.Background(), t.TempDir())
	if err == nil || !strings.Contains(err.Error(), "token.json not found") {
		t.Errorf("expected token.json not found error, got %v", err)
	}
}

func TestNewService_InvalidJSON(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "token.json"), []byte(`{not json`), 0o600)
	_, err := NewService(context.Background(), dir)
	if err == nil || !strings.Contains(err.Error(), "invalid token.json") {
		t.Errorf("expected invalid token.json error, got %v", err)
	}
}

// ── SearchMessages error path ─────────────────────────────────────────────────

func TestSearchMessages_BadRequest(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`bad request`))
	}))
	defer srv.Close()

	svc := &Service{baseURL: srv.URL, accessToken: "tok", httpClient: srv.Client()}
	_, err := svc.SearchMessages(context.Background(), "test query", 10)
	if err == nil {
		t.Error("expected error for 400 response")
	}
}

// ── apiGet additional error paths ─────────────────────────────────────────────

func TestAPIGet_DecodeError(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`not valid json`))
	}))
	defer srv.Close()

	err := apiGet(context.Background(), "tok", srv.URL, srv.Client(), &struct{ Name string }{})
	if err == nil || !strings.Contains(err.Error(), "unmarshal response") {
		t.Errorf("expected unmarshal response error, got %v", err)
	}
}

func TestAPIGet_ClientError(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	err := apiGet(ctx, "tok", "http://127.0.0.1:9", &http.Client{Timeout: time.Second}, &struct{}{})
	if err == nil {
		t.Error("expected error for cancelled context")
	}
}

// ── resolveClientCredentials missing file ─────────────────────────────────────

func TestResolveClientCredentials_MissingFile(t *testing.T) {
	t.Parallel()
	_, _, err := resolveClientCredentials(t.TempDir())
	if err == nil || !strings.Contains(err.Error(), "client_secrets.json missing") {
		t.Errorf("expected missing file error, got %v", err)
	}
}

// ── loadTokenFromFile invalid JSON ────────────────────────────────────────────

func TestLoadTokenFromFile_InvalidJSON(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	_ = os.WriteFile(GoogleTokenPath(dir), []byte(`{not json`), 0o600)
	_, _, err := loadTokenFromFile(dir)
	if err == nil || !strings.Contains(err.Error(), "invalid google_token.json") {
		t.Errorf("expected invalid json error, got %v", err)
	}
}
