package google

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/allthingscode/gobot/internal/secrets"
)

const (
	// #nosec G101 - This is a public Google OAuth2 endpoint, not a secret.
	tokenRefreshURL = "https://oauth2.googleapis.com/token"
	authURL         = "https://accounts.google.com/o/oauth2/v2/auth"
)

// tokenStore returns a SecretsStore whose storage root is derived from secretsRoot.
// secretsRoot is always {storageRoot}/secrets, so storageRoot = filepath.Dir(secretsRoot).
func tokenStore(secretsRoot string) *secrets.SecretsStore {
	return secrets.NewSecretsStore(filepath.Dir(secretsRoot))
}

// clientSecrets mirrors the format of client_secrets.json.
type clientSecrets struct {
	Installed struct {
		ClientID     string   `json:"client_id"`
		ProjectID    string   `json:"project_id"`
		AuthURI      string   `json:"auth_uri"`
		TokenURI     string   `json:"token_uri"`
		ClientSecret string   `json:"client_secret"`
		RedirectURIs []string `json:"redirect_uris"`
	} `json:"installed"`
}

// storedToken mirrors the JSON written by google-auth-library (Python).
type storedToken struct {
	Token        string    `json:"token"`
	RefreshToken string    `json:"refresh_token"`
	TokenURI     string    `json:"token_uri"`
	ClientID     string    `json:"client_id"`
	ClientSecret string    `json:"client_secret"`
	Expiry       time.Time `json:"expiry"`
}

// TimeoutClient is the shared HTTP client with a 30s timeout used for all Google API calls.
// nolint:gochecknoglobals // HTTP client is intentionally shared for connection reuse
var TimeoutClient = &http.Client{Timeout: 30 * time.Second}

// AuthorizeInteractive starts a local server to handle the OAuth2 callback,
// prints the auth URL, and returns the exchanged token.
func AuthorizeInteractive(secretsRoot string, scopes []string) error {
	clientID, clientSecret, err := resolveClientCredentials(secretsRoot)
	if err != nil {
		return err
	}

	const port = 8080
	redirectURI := fmt.Sprintf("http://localhost:%d", port)
	fullAuthURL := buildAuthURL(clientID, redirectURI, scopes)

	fmt.Println("Please open the following URL in your browser to authorize gobot:")
	fmt.Println("\n" + fullAuthURL + "\n")

	code, err := waitForAuthCode(port)
	if err != nil {
		return err
	}

	token, err := exchangeCode(context.Background(), code, clientID, clientSecret, redirectURI)
	if err != nil {
		return fmt.Errorf("token exchange: %w", err)
	}

	return persistToken(secretsRoot, token)
}

func resolveClientCredentials(secretsRoot string) (clientID, clientSecret string, err error) {
	store := tokenStore(secretsRoot)
	clientID, _ = store.Get("google_client_id")
	clientSecret, _ = store.Get("google_client_secret")

	if clientID != "" && clientSecret != "" {
		return clientID, clientSecret, nil
	}

	secretsPath := filepath.Join(secretsRoot, "client_secrets.json")
	data, err := os.ReadFile(secretsPath)
	if err != nil {
		return "", "", fmt.Errorf("client_secrets.json missing (and DPAPI keys not set): %w", err)
	}
	var cs clientSecrets
	if err := json.Unmarshal(data, &cs); err != nil {
		return "", "", fmt.Errorf("invalid client_secrets.json: %w", err)
	}
	return cs.Installed.ClientID, cs.Installed.ClientSecret, nil
}

func buildAuthURL(clientID, redirectURI string, scopes []string) string {
	v := url.Values{}
	v.Set("client_id", clientID)
	v.Set("redirect_uri", redirectURI)
	v.Set("response_type", "code")
	v.Set("scope", strings.Join(scopes, " "))
	v.Set("access_type", "offline")
	v.Set("prompt", "consent")
	return authURL + "?" + v.Encode()
}

func waitForAuthCode(port int) (string, error) {
	codeChan := make(chan string)
	errChan := make(chan error)

	// Use ListenConfig to satisfy noctx linter, although this is a short-lived
	// local listener for the OAuth flow.
	lc := net.ListenConfig{}
	l, err := lc.Listen(context.Background(), "tcp", fmt.Sprintf("localhost:%d", port))
	if err != nil {
		return "", fmt.Errorf("failed to listen on localhost:%d: %w", port, err)
	}
	defer func() { _ = l.Close() }()

	srv := &http.Server{
		ReadHeaderTimeout: 5 * time.Second,
	}
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		code := r.URL.Query().Get("code")
		if code == "" {
			fmt.Fprintf(w, "No code found in redirect. Check gobot logs.")
			errChan <- fmt.Errorf("no code in redirect")
			return
		}
		fmt.Fprintf(w, "Authorization successful! You can close this tab and return to your terminal.")
		codeChan <- code
	})

	go func() {
		if err := srv.Serve(l); err != http.ErrServerClosed {
			errChan <- err
		}
	}()

	select {
	case code := <-codeChan:
		return code, nil
	case err := <-errChan:
		return "", fmt.Errorf("auth server error: %w", err)
	case <-time.After(5 * time.Minute):
		return "", fmt.Errorf("timeout waiting for browser authorization")
	}
}

func persistToken(secretsRoot string, token *storedToken) error {
	store := tokenStore(secretsRoot)
	// nolint:gosec // RefreshToken is a secret, but we must marshal it to persist it.
	tokenJSON, err := json.MarshalIndent(token, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal token: %w", err)
	}

	if saveErr := store.Set("google_oauth_token", string(tokenJSON)); saveErr == nil {
		fmt.Println("Saved OAuth token to DPAPI secure storage.")
	}

	googlePath := GoogleTokenPath(secretsRoot)
	if err := os.WriteFile(googlePath, tokenJSON, 0o600); err != nil {
		return fmt.Errorf("failed to save google_token.json: %w", err)
	}

	gmailDir := filepath.Join(secretsRoot, "gmail")
	_ = os.MkdirAll(gmailDir, 0o755)
	gmailPath := filepath.Join(gmailDir, "token.json")
	if err := os.WriteFile(gmailPath, tokenJSON, 0o600); err != nil {
		return fmt.Errorf("failed to save gmail token: %w", err)
	}

	fmt.Printf("Successfully saved tokens to %s and %s\n", googlePath, gmailPath)
	return nil
}

func exchangeCode(ctx context.Context, code, clientID, clientSecret, redirectURI string) (*storedToken, error) {
	data := url.Values{
		"grant_type":    {"authorization_code"},
		"code":          {code},
		"client_id":     {clientID},
		"client_secret": {clientSecret},
		"redirect_uri":  {redirectURI},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, tokenRefreshURL, strings.NewReader(data.Encode()))
	if err != nil {
		return nil, fmt.Errorf("create token request: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := TimeoutClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("do token request: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read response body: %w", err)
	}

	var result struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
		ExpiresIn    int    `json:"expires_in"`
		TokenURI     string `json:"token_uri"`
		ClientID     string `json:"client_id"`
		ClientSecret string `json:"client_secret"`
		Error        string `json:"error"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, fmt.Errorf("exchange response: %w", err)
	}
	if result.Error != "" {
		return nil, fmt.Errorf("google error: %s", result.Error)
	}

	return &storedToken{
		Token:        result.AccessToken,
		RefreshToken: result.RefreshToken,
		TokenURI:     tokenRefreshURL,
		ClientID:     clientID,
		ClientSecret: clientSecret,
		Expiry:       time.Now().Add(time.Duration(result.ExpiresIn) * time.Second),
	}, nil
}

func (t *storedToken) expired() bool {
	if t.Expiry.IsZero() {
		return false
	}
	return time.Now().After(t.Expiry.Add(-30 * time.Second))
}

// GoogleTokenPath returns the path to the Google Calendar/Tasks token.
//
// revive:disable:exported
func GoogleTokenPath(secretsRoot string) string {
	return filepath.Join(secretsRoot, "google_token.json")
}

// BearerToken loads the token from secretsRoot/google_token.json, refreshes if
// expired, persists the refreshed token, and returns a valid access token string.
// Returns an error if the file is missing or refresh fails.
func BearerToken(ctx context.Context, secretsRoot string) (string, error) {
	return bearerTokenWithClient(ctx, secretsRoot, TimeoutClient)
}

// bearerTokenWithClient is the testable inner implementation.
func bearerTokenWithClient(ctx context.Context, secretsRoot string, client *http.Client) (string, error) {
	if token, ok := tryLoadTokenFromDPAPI(ctx, secretsRoot, client); ok {
		return token, nil
	}

	tok, path, err := loadTokenFromFile(secretsRoot)
	if err != nil {
		return "", err
	}

	if tok.expired() {
		if err := refreshAndSaveToken(ctx, tok, path, client); err != nil {
			return "", err
		}
	}
	return tok.Token, nil
}

func tryLoadTokenFromDPAPI(ctx context.Context, secretsRoot string, client *http.Client) (string, bool) {
	store := tokenStore(secretsRoot)
	tokenJSON, err := store.Get("google_oauth_token")
	if err != nil || tokenJSON == "" {
		return "", false
	}

	var tok storedToken
	if err := json.Unmarshal([]byte(tokenJSON), &tok); err != nil {
		return "", false
	}

	if tok.expired() {
		if tok.RefreshToken == "" {
			return "", false
		}
		if err := refreshToken(ctx, &tok, client); err != nil {
			return "", false
		}
		// nolint:gosec // RefreshToken is a secret, but we must marshal it to persist it.
		if updated, err := json.Marshal(tok); err == nil {
			_ = store.Set("google_oauth_token", string(updated))
		}
	}
	return tok.Token, true
}

func loadTokenFromFile(secretsRoot string) (*storedToken, string, error) {
	path := GoogleTokenPath(secretsRoot)
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, "", fmt.Errorf("google_token.json not found at %s: %w", path, err)
	}

	var tok storedToken
	if err := json.Unmarshal(data, &tok); err != nil {
		return nil, "", fmt.Errorf("invalid google_token.json: %w", err)
	}
	return &tok, path, nil
}

func refreshAndSaveToken(ctx context.Context, tok *storedToken, path string, client *http.Client) error {
	if tok.RefreshToken == "" {
		return fmt.Errorf("google token expired and no refresh_token present")
	}
	if err := refreshToken(ctx, tok, client); err != nil {
		return fmt.Errorf("google token refresh: %w", err)
	}
	// nolint:gosec // RefreshToken is a secret
	if updated, err := json.Marshal(tok); err == nil {
		_ = os.WriteFile(path, updated, 0o600)
	}
	return nil
}

// refreshToken exchanges a refresh_token for a new access token, updating tok in place.
func refreshToken(ctx context.Context, tok *storedToken, client *http.Client) error {
	tokenURI := tok.TokenURI
	if tokenURI == "" {
		tokenURI = tokenRefreshURL
	}
	data := url.Values{
		"grant_type":    {"refresh_token"},
		"refresh_token": {tok.RefreshToken},
		"client_id":     {tok.ClientID},
		"client_secret": {tok.ClientSecret},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, tokenURI, strings.NewReader(data.Encode()))
	if err != nil {
		return fmt.Errorf("build refresh request: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("token refresh request: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("read response body: %w", err)
	}
	var result struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
		Error       string `json:"error"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		return fmt.Errorf("invalid token refresh response: %w", err)
	}
	if result.Error != "" {
		return fmt.Errorf("%s", result.Error)
	}
	tok.Token = result.AccessToken
	if result.ExpiresIn > 0 {
		tok.Expiry = time.Now().Add(time.Duration(result.ExpiresIn) * time.Second)
	}
	return nil
}

// apiGet performs an authenticated GET to the given URL and decodes the JSON
// response body into dest.
func apiGet(ctx context.Context, accessToken, apiURL string, client *http.Client, dest any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, apiURL, http.NoBody)
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("GET %s: %w", apiURL, err)
	}
	defer func() { _ = resp.Body.Close() }()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("read response body: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		// Try to extract error message
		var errResp struct {
			Error struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		_ = json.Unmarshal(body, &errResp)
		if strings.Contains(errResp.Error.Message, "Invalid Credentials") ||
			strings.Contains(errResp.Error.Message, "401") {
			return fmt.Errorf("google API 401: token may be expired, run gobot reauth-google")
		}
		return fmt.Errorf("google API %d: %s", resp.StatusCode, string(body))
	}
	if err := json.Unmarshal(body, dest); err != nil {
		return fmt.Errorf("unmarshal response: %w", err)
	}
	return nil
}

// doGoogleRequest performs an authenticated HTTP request with a JSON body
// and decodes the JSON response into dest.
func doGoogleRequest(ctx context.Context, method, accessToken, apiURL string, body any, client *http.Client, dest any) error {
	payload, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("marshal body: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, method, apiURL, strings.NewReader(string(payload)))
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("%s %s: %w", method, apiURL, err)
	}
	defer func() { _ = resp.Body.Close() }()
	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("read response body: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return fmt.Errorf("google API %d: %s", resp.StatusCode, string(respBody))
	}
	if err := json.Unmarshal(respBody, dest); err != nil {
		return fmt.Errorf("decode response: %w", err)
	}
	return nil
}

// apiPost performs an authenticated POST with a JSON body and decodes the
// JSON response into dest.
func apiPost(ctx context.Context, accessToken, apiURL string, body any, client *http.Client, dest any) error {
	return doGoogleRequest(ctx, http.MethodPost, accessToken, apiURL, body, client, dest)
}

// apiPatch performs an authenticated PATCH with a JSON body and decodes the
// JSON response into dest.
func apiPatch(ctx context.Context, accessToken, apiURL string, body any, client *http.Client, dest any) error {
	return doGoogleRequest(ctx, http.MethodPatch, accessToken, apiURL, body, client, dest)
}
