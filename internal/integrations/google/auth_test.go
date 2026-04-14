//nolint:testpackage // requires unexported auth internals for testing
package google

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"
)

func TestBearerToken_ValidNotExpired(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	tok := storedToken{
		Token:        "valid-access-token", // nolint:gosec // test key
		RefreshToken: "refresh",            // nolint:gosec // test key
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
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if err := json.NewEncoder(w).Encode(map[string]any{
			"access_token": "new-token",
			"expires_in":   3600,
		}); err != nil {
			t.Fatal(err)
		}
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
	if got != "new-token" { //nolint:goconst // test fixture token
		t.Errorf("want new-token, got %q", got)
	}
}

func TestBearerToken_MissingFile(t *testing.T) {
	t.Parallel()
	_, err := BearerToken(t.TempDir())
	if err == nil {
		t.Fatal("expected error for missing token file")
	}
}

func TestBearerToken_NoRefreshToken(t *testing.T) {
	t.Parallel()
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

func TestAPIGet_Success(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer tok" {
			t.Errorf("want Authorization: Bearer tok, got %q", r.Header.Get("Authorization"))
		}
		if err := json.NewEncoder(w).Encode(map[string]string{"id": "evt1"}); err != nil {
			t.Fatal(err)
		}
	}))
	defer srv.Close()

	var got struct {
		ID string `json:"id"`
	}
	if err := apiGet("tok", srv.URL, srv.Client(), &got); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.ID != "evt1" {
		t.Errorf("want evt1, got %q", got.ID)
	}
}

func TestAPIGet_HTTPError(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, `{"error":{"message":"not found"}}`, http.StatusNotFound)
	}))
	defer srv.Close()

	err := apiGet("tok", srv.URL, srv.Client(), &struct{}{})
	if err == nil {
		t.Fatal("expected error for 404 response")
	}
}

func TestAPIPost_Success(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Errorf("want POST, got %s", r.Method)
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"id": "new-id-123"})
	}))
	defer srv.Close()

	var got struct {
		ID string `json:"id"`
	}
	err := apiPost("tok", srv.URL, map[string]string{"title": "test"}, srv.Client(), &got)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.ID != "new-id-123" {
		t.Errorf("want new-id-123, got %q", got.ID)
	}
}

func TestAPIPost_HTTPError(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "server error", http.StatusInternalServerError)
	}))
	defer srv.Close()

	err := apiPost("tok", srv.URL, map[string]string{}, srv.Client(), &struct{}{})
	if err == nil {
		t.Fatal("expected error for 500 response")
	}
}

// redirectClient returns an *http.Client that rewrites the URL prefix from → to.
// Used in tests to redirect production API base URLs to httptest servers.
func redirectClient(from, to string) *http.Client {
	return &http.Client{Transport: &prefixRewriter{from: from, to: to}}
}

type prefixRewriter struct{ from, to string }

func (r *prefixRewriter) RoundTrip(req *http.Request) (*http.Response, error) {
	rawURL := strings.Replace(req.URL.String(), r.from, r.to, 1)
	newURL, err := url.Parse(rawURL)
	if err != nil {
		return nil, err
	}
	r2 := req.Clone(req.Context())
	r2.URL = newURL
	r2.Host = newURL.Host
	return http.DefaultTransport.RoundTrip(r2)
}

// writeToken marshals tok and writes to dir/google_token.json.
func writeToken(t *testing.T, dir string, tok storedToken) {
	t.Helper()
	data, err := json.Marshal(tok)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(GoogleTokenPath(dir), data, 0o600); err != nil {
		t.Fatal(err)
	}
}
