package google

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"
)

func TestBearerToken_ValidNotExpired(t *testing.T) {
	dir := t.TempDir()
	tok := storedToken{
		Token:        "valid-access-token",
		RefreshToken: "refresh",
		TokenURI:     "https://oauth2.googleapis.com/token",
		ClientID:     "cid",
		ClientSecret: "csec",
		Expiry:       time.Now().Add(1 * time.Hour), // not expired
	}
	writeToken(t, dir, tok)
	got, err := BearerToken(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "valid-access-token" {
		t.Errorf("want valid-access-token, got %q", got)
	}
}

func TestBearerToken_ExpiredRefreshes(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{
			"access_token": "new-token",
			"expires_in":   3600,
		})
	}))
	defer srv.Close()

	dir := t.TempDir()
	tok := storedToken{
		Token:        "old-token",
		RefreshToken: "refresh",
		TokenURI:     srv.URL,
		ClientID:     "cid",
		ClientSecret: "csec",
		Expiry:       time.Now().Add(-1 * time.Hour), // expired
	}
	writeToken(t, dir, tok)

	got, err := bearerTokenWithClient(dir, srv.Client())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "new-token" {
		t.Errorf("want new-token, got %q", got)
	}
}

func TestBearerToken_MissingFile(t *testing.T) {
	_, err := BearerToken(t.TempDir())
	if err == nil {
		t.Fatal("expected error for missing token file")
	}
}

func TestBearerToken_NoRefreshToken(t *testing.T) {
	dir := t.TempDir()
	tok := storedToken{
		Token:  "old",
		Expiry: time.Now().Add(-1 * time.Hour),
	}
	writeToken(t, dir, tok)
	_, err := BearerToken(dir)
	if err == nil {
		t.Fatal("expected error when no refresh_token")
	}
}

// writeToken marshals tok and writes to dir/google_token.json.
func writeToken(t *testing.T, dir string, tok storedToken) {
	t.Helper()
	data, err := json.Marshal(tok)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(GoogleTokenPath(dir), data, 0600); err != nil {
		t.Fatal(err)
	}
}
