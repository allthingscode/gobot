package gmail

import (
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

// writeToken is a test helper that writes a storedToken as token.json in dir.
func writeToken(t *testing.T, dir string, tok storedToken) {
	t.Helper()
	data, err := json.Marshal(tok)
	if err != nil {
		t.Fatalf("marshal token: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "token.json"), data, 0600); err != nil {
		t.Fatalf("write token.json: %v", err)
	}
}

func TestNewService_MissingToken(t *testing.T) {
	_, err := NewService(t.TempDir())
	if err == nil {
		t.Fatal("expected error for missing token.json")
	}
	if !strings.Contains(err.Error(), "token.json not found") {
		t.Errorf("unexpected error message: %v", err)
	}
}

func TestNewService_InvalidJSON(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "token.json"), []byte("not json"), 0600); err != nil {
		t.Fatal(err)
	}
	_, err := NewService(dir)
	if err == nil {
		t.Fatal("expected error for invalid JSON")
	}
}

func TestNewService_ValidToken(t *testing.T) {
	dir := t.TempDir()
	writeToken(t, dir, storedToken{
		Token:        "valid-access-token",
		RefreshToken: "refresh-token",
		Expiry:       time.Now().Add(1 * time.Hour),
	})

	sender, err := NewService(dir)
	if err != nil {
		t.Fatalf("NewService failed: %v", err)
	}
	if sender == nil {
		t.Fatal("expected non-nil sender")
	}
	gs := sender.(*gmailSender)
	if gs.accessToken != "valid-access-token" {
		t.Errorf("accessToken = %q, want %q", gs.accessToken, "valid-access-token")
	}
}

func TestNewService_ExpiredNoRefreshToken(t *testing.T) {
	dir := t.TempDir()
	writeToken(t, dir, storedToken{
		Token:  "expired-token",
		Expiry: time.Now().Add(-1 * time.Hour),
	})

	_, err := NewService(dir)
	if !errors.Is(err, ErrNeedsReauth) {
		t.Fatalf("expected ErrNeedsReauth, got: %v", err)
	}
}

func TestNewService_ExpiredRefreshesSuccessfully(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"access_token": "new-access-token",
			"expires_in":   3600,
		})
	}))
	defer srv.Close()

	dir := t.TempDir()
	writeToken(t, dir, storedToken{
		Token:        "old-token",
		RefreshToken: "valid-refresh-token",
		ClientID:     "client-id",
		ClientSecret: "client-secret",
		TokenURI:     srv.URL,
		Expiry:       time.Now().Add(-1 * time.Hour),
	})

	sender, err := NewService(dir)
	if err != nil {
		t.Fatalf("NewService failed: %v", err)
	}
	gs := sender.(*gmailSender)
	if gs.accessToken != "new-access-token" {
		t.Errorf("accessToken = %q, want %q", gs.accessToken, "new-access-token")
	}

	// Verify token.json was updated on disk.
	data, _ := os.ReadFile(filepath.Join(dir, "token.json"))
	var saved storedToken
	if err := json.Unmarshal(data, &saved); err != nil {
		t.Fatalf("re-read token.json: %v", err)
	}
	if saved.Token != "new-access-token" {
		t.Errorf("persisted token = %q, want %q", saved.Token, "new-access-token")
	}
}

func TestNewService_InvalidGrant(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"error": "invalid_grant"})
	}))
	defer srv.Close()

	dir := t.TempDir()
	writeToken(t, dir, storedToken{
		Token:        "old-token",
		RefreshToken: "bad-refresh",
		TokenURI:     srv.URL,
		Expiry:       time.Now().Add(-1 * time.Hour),
	})

	_, err := NewService(dir)
	if !errors.Is(err, ErrNeedsReauth) {
		t.Fatalf("expected ErrNeedsReauth for invalid_grant, got: %v", err)
	}
}

func TestSend_PlainText(t *testing.T) {
	var capturedAuth string
	var capturedPayload map[string]string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		capturedAuth = r.Header.Get("Authorization")
		json.NewDecoder(r.Body).Decode(&capturedPayload)
		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(map[string]string{"id": "msg-001"})
	}))
	defer srv.Close()

	s := &gmailSender{
		accessToken: "test-token",
		endpoint:    srv.URL,
		httpClient:  http.DefaultClient,
	}

	if err := s.Send("user@example.com", "Hello", "plain text body"); err != nil {
		t.Fatalf("Send failed: %v", err)
	}
	if capturedAuth != "Bearer test-token" {
		t.Errorf("Authorization = %q, want %q", capturedAuth, "Bearer test-token")
	}
	raw, ok := capturedPayload["raw"]
	if !ok || raw == "" {
		t.Errorf("request body missing 'raw' field: %v", capturedPayload)
	}
	decoded, err := base64.URLEncoding.DecodeString(raw)
	if err != nil {
		t.Fatalf("base64 decode: %v", err)
	}
	mime := string(decoded)
	if !strings.Contains(mime, "To: user@example.com") {
		t.Errorf("MIME missing To header: %s", mime)
	}
	if !strings.Contains(mime, "plain text body") {
		t.Errorf("MIME missing body: %s", mime)
	}
	if strings.Contains(mime, "text/html") {
		t.Errorf("plain text body should not have HTML content-type: %s", mime)
	}
}

func TestSend_HTMLWrapped(t *testing.T) {
	var capturedPayload map[string]string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewDecoder(r.Body).Decode(&capturedPayload)
		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(map[string]string{"id": "msg-002"})
	}))
	defer srv.Close()

	s := &gmailSender{
		accessToken: "test-token",
		endpoint:    srv.URL,
		httpClient:  http.DefaultClient,
	}

	if err := s.Send("user@example.com", "Report", "<h1>Title</h1><p>Body</p>"); err != nil {
		t.Fatalf("Send failed: %v", err)
	}
	raw := capturedPayload["raw"]
	if raw == "" {
		t.Fatal("expected raw field in payload")
	}
	decoded, err := base64.URLEncoding.DecodeString(raw)
	if err != nil {
		t.Fatalf("base64 decode: %v", err)
	}
	mimeStr := string(decoded)
	if !strings.Contains(mimeStr, "Content-Type: text/html") {
		t.Errorf("expected HTML content-type in MIME, got: %s", mimeStr)
	}
	if !strings.Contains(mimeStr, "container") {
		t.Errorf("expected CSS wrapper (container class) in body, got: %s", truncate(mimeStr, 300))
	}
}

func TestSend_APIError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		w.Write([]byte(`{"error": "invalid credentials"}`))
	}))
	defer srv.Close()

	s := &gmailSender{
		accessToken: "bad-token",
		endpoint:    srv.URL,
		httpClient:  http.DefaultClient,
	}

	err := s.Send("user@example.com", "Test", "body")
	if err == nil {
		t.Fatal("expected error for API 401")
	}
	if !strings.Contains(err.Error(), "401") {
		t.Errorf("error should mention status code, got: %v", err)
	}
}

func TestStoredToken_Expired(t *testing.T) {
	tests := []struct {
		name    string
		tok     storedToken
		wantExp bool
	}{
		{"zero expiry is not expired", storedToken{}, false},
		{"future expiry is not expired", storedToken{Expiry: time.Now().Add(1 * time.Hour)}, false},
		{"past expiry is expired", storedToken{Expiry: time.Now().Add(-1 * time.Hour)}, true},
		{"within 30s grace is expired", storedToken{Expiry: time.Now().Add(20 * time.Second)}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := tt.tok.expired(); got != tt.wantExp {
				t.Errorf("expired() = %v, want %v", got, tt.wantExp)
			}
		})
	}
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}
