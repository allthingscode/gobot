//nolint:testpackage // requires unexported auth internals for testing
package google

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestBearerToken_ValidNotExpired(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	tok := storedToken{ //nolint:gosec // G101: test credentials, not real secrets
		Token:        "valid-access-token",
		RefreshToken: "refresh",
		TokenURI:     "https://oauth2.googleapis.com/token",
		ClientID:     "cid",
		ClientSecret: "csec",
		Expiry:       time.Now().Add(1 * time.Hour), // not expired
	}
	writeToken(t, dir, tok)
	got, err := BearerToken(context.Background(), dir)
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

	got, err := bearerTokenWithClient(context.Background(), dir, srv.Client())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "new-token" { //nolint:goconst // test fixture token
		t.Errorf("want new-token, got %q", got)
	}
	tokenData, err := os.ReadFile(GoogleTokenPath(dir))
	if err != nil {
		t.Fatalf("read refreshed token: %v", err)
	}
	var refreshed storedToken
	if err := json.Unmarshal(tokenData, &refreshed); err != nil {
		t.Fatalf("unmarshal refreshed token: %v", err)
	}
	if refreshed.Token != "new-token" {
		t.Fatalf("persisted token = %q, want new-token", refreshed.Token)
	}
}

type secureStoreRefreshCase struct {
	name              string
	oldAccessToken    string
	refreshToken      string
	clientID          string
	clientSecret      string
	refreshedToken    string
	refreshedLifetime int
}

func TestBearerToken_SecureStoreExpiredRefreshesAndPersists(t *testing.T) {
	t.Parallel()

	tests := []secureStoreRefreshCase{
		{
			name:              "expired_token_from_secure_store",
			oldAccessToken:    "secure-old-token",
			refreshToken:      "secure-refresh-token",
			clientID:          "secure-client-id",
			clientSecret:      "secure-client-secret",
			refreshedToken:    "secure-new-token",
			refreshedLifetime: 3600,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			runSecureStoreRefreshTest(t, tt)
		})
	}
}

func runSecureStoreRefreshTest(t *testing.T, tt secureStoreRefreshCase) {
	t.Helper()

	refreshForms := make(chan url.Values, 1)
	srv := httptest.NewServer(secureStoreRefreshHandler(t, tt, refreshForms))
	defer srv.Close()

	store, secretsRoot := seedSecureStoreToken(t, tt, srv.URL)
	got, err := bearerTokenWithClient(context.Background(), secretsRoot, srv.Client())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != tt.refreshedToken {
		t.Fatalf("token = %q, want %q", got, tt.refreshedToken)
	}

	assertRefreshForm(t, <-refreshForms, tt)
	assertPersistedSecureStoreToken(t, store, tt)
}

func secureStoreRefreshHandler(t *testing.T, tt secureStoreRefreshCase, forms chan<- url.Values) http.Handler {
	t.Helper()

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Errorf("want POST, got %s", r.Method)
		}
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1024))
		if err != nil {
			t.Fatalf("read refresh form: %v", err)
		}
		form, err := url.ParseQuery(string(body))
		if err != nil {
			t.Fatalf("parse refresh form: %v", err)
		}
		forms <- form
		if err := json.NewEncoder(w).Encode(map[string]any{
			"access_token": tt.refreshedToken,
			"expires_in":   tt.refreshedLifetime,
		}); err != nil {
			t.Fatal(err)
		}
	})
}

func seedSecureStoreToken(t *testing.T, tt secureStoreRefreshCase, tokenURI string) (store secretsStore, secretsRoot string) {
	t.Helper()

	storageRoot := t.TempDir()
	secretsRoot = filepath.Join(storageRoot, "secrets")
	store = tokenStore(secretsRoot)
	stored := storedToken{
		Token:        tt.oldAccessToken,
		RefreshToken: tt.refreshToken,
		TokenURI:     tokenURI,
		ClientID:     tt.clientID,
		ClientSecret: tt.clientSecret,
		Expiry:       time.Now().Add(-1 * time.Hour),
	}
	tokenJSON, err := json.Marshal(stored) //nolint:gosec // RefreshToken is a test fixture.
	if err != nil {
		t.Fatalf("marshal stored token: %v", err)
	}
	if err := store.Set("google_oauth_token", string(tokenJSON)); err != nil {
		t.Fatalf("seed secure-store token: %v", err)
	}
	seeded := readSecureStoreToken(t, store, "seeded")
	if seeded.Token != tt.oldAccessToken {
		t.Fatalf("seeded secure-store token = %q, want %q", seeded.Token, tt.oldAccessToken)
	}
	if seeded.RefreshToken != tt.refreshToken {
		t.Fatalf("seeded secure-store refresh token = %q, want %q", seeded.RefreshToken, tt.refreshToken)
	}
	return store, secretsRoot
}

type secretsStore = interface {
	Set(key, value string) error
	Get(key string) (string, error)
}

func assertRefreshForm(t *testing.T, gotForm url.Values, tt secureStoreRefreshCase) {
	t.Helper()

	wantForm := url.Values{
		"grant_type":    {"refresh_token"},
		"refresh_token": {tt.refreshToken},
		"client_id":     {tt.clientID},
		"client_secret": {tt.clientSecret},
	}
	for key, want := range wantForm {
		if got := gotForm[key]; strings.Join(got, "\x00") != strings.Join(want, "\x00") {
			t.Errorf("refresh form %s = %q, want %q", key, got, want)
		}
	}
}

func assertPersistedSecureStoreToken(t *testing.T, store secretsStore, tt secureStoreRefreshCase) {
	t.Helper()

	persisted := readSecureStoreToken(t, store, "persisted")
	if persisted.Token != tt.refreshedToken {
		t.Errorf("persisted token = %q, want %q", persisted.Token, tt.refreshedToken)
	}
	if persisted.RefreshToken != tt.refreshToken {
		t.Errorf("persisted refresh token = %q, want %q", persisted.RefreshToken, tt.refreshToken)
	}
	if time.Until(persisted.Expiry) < 50*time.Minute {
		t.Errorf("persisted expiry = %s, want at least 50m in the future", persisted.Expiry)
	}
}

func readSecureStoreToken(t *testing.T, store secretsStore, stage string) storedToken {
	t.Helper()

	persistedJSON, err := store.Get("google_oauth_token")
	if err != nil {
		t.Fatalf("read %s secure-store token: %v", stage, err)
	}
	if persistedJSON == "" {
		// tryLoadTokenFromDPAPI treats a missing secure-store key as a normal
		// fallback-to-file condition; this secure-store-specific test must fail
		// at the setup/use boundary instead of later on google_token.json.
		t.Fatalf("%s secure-store token is missing", stage)
	}
	var persisted storedToken
	if err := json.Unmarshal([]byte(persistedJSON), &persisted); err != nil {
		t.Fatalf("unmarshal %s secure-store token: %v", stage, err)
	}
	return persisted
}

func TestBearerToken_MissingFile(t *testing.T) {
	t.Parallel()
	_, err := BearerToken(context.Background(), t.TempDir())
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
	_, err := BearerToken(context.Background(), dir)
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
	if err := apiGet(context.Background(), "tok", srv.URL, srv.Client(), &got); err != nil {
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

	err := apiGet(context.Background(), "tok", srv.URL, srv.Client(), &struct{}{})
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
	err := apiPost(context.Background(), "tok", srv.URL, map[string]string{"title": "test"}, srv.Client(), &got)
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

	err := apiPost(context.Background(), "tok", srv.URL, map[string]string{}, srv.Client(), &struct{}{})
	if err == nil {
		t.Fatal("expected error for 500 response")
	}
}

func writeToken(t *testing.T, dir string, tok storedToken) {
	t.Helper()
	data, err := json.Marshal(tok) //nolint:gosec // RefreshToken is a secret, but we must marshal it to persist it.
	if err != nil {
		t.Fatal(err)
	}
	path := GoogleTokenPath(dir)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
}

// redirectClient returns an *http.Client that rewrites the URL prefix from → to.
// Used in tests to redirect production API base URLs to httptest servers.
func redirectClient(from, to string) *http.Client {
	return &http.Client{
		Transport: &prefixRewriter{
			from: from,
			to:   to,
		},
	}
}

type prefixRewriter struct {
	from string
	to   string
}

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
