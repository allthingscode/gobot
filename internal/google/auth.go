package google

import (
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
)

const (
	tokenRefreshURL = "https://oauth2.googleapis.com/token"
	authURL         = "https://accounts.google.com/o/oauth2/v2/auth"
)

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

// AuthorizeInteractive starts a local server to handle the OAuth2 callback,
// prints the auth URL, and returns the exchanged token.
func AuthorizeInteractive(secretsRoot string, scopes []string) error {
	secretsPath := filepath.Join(secretsRoot, "client_secrets.json")
	data, err := os.ReadFile(secretsPath)
	if err != nil {
		return fmt.Errorf("client_secrets.json missing: %w", err)
	}
	var secrets clientSecrets
	if err := json.Unmarshal(data, &secrets); err != nil {
		return fmt.Errorf("invalid client_secrets.json: %w", err)
	}

	// Use a fixed port 8080 to match most client secrets
	port := 8080
	redirectURI := fmt.Sprintf("http://localhost:%d", port)

	v := url.Values{}
	v.Set("client_id", secrets.Installed.ClientID)
	v.Set("redirect_uri", redirectURI)
	v.Set("response_type", "code")
	v.Set("scope", strings.Join(scopes, " "))
	v.Set("access_type", "offline")
	v.Set("prompt", "consent") // Force refresh token

	fullAuthURL := authURL + "?" + v.Encode()

	fmt.Println("Please open the following URL in your browser to authorize gobot:")
	fmt.Println("\n" + fullAuthURL + "\n")

	// Start local server to catch the code
	codeChan := make(chan string)
	errChan := make(chan error)

	l, err := net.Listen("tcp", fmt.Sprintf("localhost:%d", port))
	if err != nil {
		return fmt.Errorf("failed to listen on localhost:%d: %w", port, err)
	}
	defer l.Close()

	srv := &http.Server{}
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

	var code string
	select {
	case code = <-codeChan:
		// success
	case err := <-errChan:
		return fmt.Errorf("auth server error: %w", err)
	case <-time.After(5 * time.Minute):
		return fmt.Errorf("timeout waiting for browser authorization")
	}

	// Exchange code for token
	token, err := exchangeCode(code, secrets.Installed.ClientID, secrets.Installed.ClientSecret, redirectURI)
	if err != nil {
		return fmt.Errorf("token exchange: %w", err)
	}

	// Save to both google_token.json and gmail/token.json for compatibility
	tokenJSON, _ := json.MarshalIndent(token, "", "  ")

	googlePath := GoogleTokenPath(secretsRoot)
	if err := os.WriteFile(googlePath, tokenJSON, 0600); err != nil {
		return fmt.Errorf("failed to save google_token.json: %w", err)
	}

	gmailDir := filepath.Join(secretsRoot, "gmail")
	os.MkdirAll(gmailDir, 0755)
	gmailPath := filepath.Join(gmailDir, "token.json")
	if err := os.WriteFile(gmailPath, tokenJSON, 0600); err != nil {
		return fmt.Errorf("failed to save gmail token: %w", err)
	}

	fmt.Printf("Successfully saved tokens to %s and %s\n", googlePath, gmailPath)
	return nil
}

func exchangeCode(code, clientID, clientSecret, redirectURI string) (*storedToken, error) {
	resp, err := http.PostForm(tokenRefreshURL, url.Values{
		"grant_type":    {"authorization_code"},
		"code":          {code},
		"client_id":     {clientID},
		"client_secret": {clientSecret},
		"redirect_uri":  {redirectURI},
	})
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)

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
func GoogleTokenPath(secretsRoot string) string {
	return filepath.Join(secretsRoot, "google_token.json")
}

// BearerToken loads the token from secretsRoot/google_token.json, refreshes if
// expired, persists the refreshed token, and returns a valid access token string.
// Returns an error if the file is missing or refresh fails.
func BearerToken(secretsRoot string) (string, error) {
	return bearerTokenWithClient(secretsRoot, http.DefaultClient)
}

// bearerTokenWithClient is the testable inner implementation.
func bearerTokenWithClient(secretsRoot string, client *http.Client) (string, error) {
	tokenPath := GoogleTokenPath(secretsRoot)
	data, err := os.ReadFile(tokenPath)
	if err != nil {
		return "", fmt.Errorf("google_token.json not found at %s: %w", tokenPath, err)
	}

	var tok storedToken
	if err := json.Unmarshal(data, &tok); err != nil {
		return "", fmt.Errorf("invalid google_token.json: %w", err)
	}

	if tok.expired() {
		if tok.RefreshToken == "" {
			return "", fmt.Errorf("google token expired and no refresh_token present")
		}
		if err := refreshToken(&tok, client); err != nil {
			return "", fmt.Errorf("google token refresh: %w", err)
		}
		if updated, err := json.Marshal(tok); err == nil {
			_ = os.WriteFile(tokenPath, updated, 0600)
		}
	}
	return tok.Token, nil
}

// refreshToken exchanges a refresh_token for a new access token, updating tok in place.
func refreshToken(tok *storedToken, client *http.Client) error {
	tokenURI := tok.TokenURI
	if tokenURI == "" {
		tokenURI = tokenRefreshURL
	}
	resp, err := client.PostForm(tokenURI, url.Values{
		"grant_type":    {"refresh_token"},
		"refresh_token": {tok.RefreshToken},
		"client_id":     {tok.ClientID},
		"client_secret": {tok.ClientSecret},
	})
	if err != nil {
		return fmt.Errorf("token refresh request: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
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
func apiGet(accessToken, apiURL string, client *http.Client, dest any) error {
	req, err := http.NewRequest(http.MethodGet, apiURL, nil)
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("GET %s: %w", apiURL, err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
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
	return json.Unmarshal(body, dest)
}

// apiPost performs an authenticated POST with a JSON body and decodes the
// JSON response into dest.
func apiPost(accessToken, apiURL string, body any, client *http.Client, dest any) error {
	payload, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("marshal body: %w", err)
	}
	req, err := http.NewRequest(http.MethodPost, apiURL, strings.NewReader(string(payload)))
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("POST %s: %w", apiURL, err)
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return fmt.Errorf("google API %d: %s", resp.StatusCode, string(respBody))
	}
	return json.Unmarshal(respBody, dest)
}
