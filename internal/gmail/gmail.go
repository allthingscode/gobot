// Package gmail provides OAuth2 token management and email delivery via the Gmail API.
// It uses only the standard library and the internal reporter package — no Google SDK required.
package gmail

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/allthingscode/gobot/internal/reporter"
	"github.com/allthingscode/gobot/internal/resilience"
)

// ErrNeedsReauth is returned when the OAuth2 token is expired and cannot be refreshed
// automatically (missing refresh token or invalid_grant from the token endpoint).
// The caller should direct the user to run `gobot reauth`.
var ErrNeedsReauth = errors.New("AUTH_EXPIRED: run gobot reauth")

// gmailAPIURL is the Gmail messages.send endpoint. Overridable in tests.
const gmailAPIURL = "https://gmail.googleapis.com/gmail/v1/users/me/messages/send"

// tokenRefreshURL is the default OAuth2 token endpoint.
const tokenRefreshURL = "https://oauth2.googleapis.com/token"

var timeoutClient = &http.Client{Timeout: 30 * time.Second}

// storedToken mirrors the JSON structure written by google-auth-library (Python).
// Fields match the token.json format saved by InstalledAppFlow.
type storedToken struct {
	Token        string    `json:"token"`
	RefreshToken string    `json:"refresh_token"`
	TokenURI     string    `json:"token_uri"`
	ClientID     string    `json:"client_id"`
	ClientSecret string    `json:"client_secret"`
	Expiry       time.Time `json:"expiry"`
}

func (t *storedToken) expired() bool {
	if t.Expiry.IsZero() {
		return false
	}
	// Treat token as expired 30 seconds early to avoid edge-case clock skew.
	return time.Now().After(t.Expiry.Add(-30 * time.Second))
}

// Sender delivers email messages. Implemented by gmailSender; mockable in tests.
type Sender interface {
	Send(ctx context.Context, to, subject, body string) error
}

// gmailSender is the production Sender backed by the Gmail REST API.
type gmailSender struct {
	accessToken string
	endpoint    string       // injectable for tests; defaults to gmailAPIURL
	httpClient  *http.Client // injectable for tests; defaults to http.DefaultClient
}

// NewService loads OAuth2 credentials from {secretsRoot}/token.json and returns a Sender.
// If the token is expired and has a refresh token, it refreshes automatically and
// persists the new token. Returns ErrNeedsReauth if refresh is impossible.
func NewService(secretsRoot string) (Sender, error) {
	tokenPath := filepath.Join(secretsRoot, "token.json")
	data, err := os.ReadFile(tokenPath)
	if err != nil {
		return nil, fmt.Errorf("token.json not found at %s: %w", tokenPath, err)
	}

	var tok storedToken
	if err := json.Unmarshal(data, &tok); err != nil {
		return nil, fmt.Errorf("invalid token.json: %w", err)
	}

	if tok.expired() {
		if tok.RefreshToken == "" {
			return nil, ErrNeedsReauth
		}
		if err := refreshToken(&tok, timeoutClient); err != nil {
			if strings.Contains(err.Error(), "invalid_grant") {
				return nil, ErrNeedsReauth
			}
			return nil, fmt.Errorf("token refresh failed: %w", err)
		}
		// Persist the refreshed token so the next call doesn't re-refresh.
		if updated, err := json.Marshal(tok); err == nil {
			_ = os.WriteFile(tokenPath, updated, 0600)
		}
	}

	return &gmailSender{
		accessToken: tok.Token,
		endpoint:    gmailAPIURL,
		httpClient:  timeoutClient,
	}, nil
}

// refreshToken calls the OAuth2 token endpoint to exchange a refresh token for a new
// access token, updating tok in place.
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

const multipartBoundary = "gobot_alt_20260328"

// Send delivers an email via the Gmail API.
// HTML bodies (detected by reporter.WrapHTML) are sent as multipart/alternative
// with a text/plain fallback; plain-text bodies are sent as text/plain.
func (s *gmailSender) Send(ctx context.Context, to, subject, body string) error {
	wrapped := reporter.WrapHTML(body)
	isHTML := wrapped != body

	var sb strings.Builder
	sb.WriteString("To: " + to + "\r\n")
	sb.WriteString("Subject: " + mime.QEncoding.Encode("UTF-8", subject) + "\r\n")
	sb.WriteString("MIME-Version: 1.0\r\n")

	if isHTML {
		plainText := reporter.StripHTML(wrapped)
		sb.WriteString("Content-Type: multipart/alternative; boundary=\"" + multipartBoundary + "\"\r\n")
		sb.WriteString("\r\n")

		// Part 1: plain text
		sb.WriteString("--" + multipartBoundary + "\r\n")
		sb.WriteString("Content-Type: text/plain; charset=UTF-8\r\n")
		sb.WriteString("\r\n")
		sb.WriteString(plainText)
		sb.WriteString("\r\n\r\n")

		// Part 2: HTML
		sb.WriteString("--" + multipartBoundary + "\r\n")
		sb.WriteString("Content-Type: text/html; charset=UTF-8\r\n")
		sb.WriteString("\r\n")
		sb.WriteString(wrapped)
		sb.WriteString("\r\n\r\n")

		// Closing boundary
		sb.WriteString("--" + multipartBoundary + "--\r\n")
	} else {
		sb.WriteString("Content-Type: text/plain; charset=UTF-8\r\n")
		sb.WriteString("\r\n")
		sb.WriteString(body)
	}

	raw := base64.URLEncoding.EncodeToString([]byte(sb.String()))
	payload, err := json.Marshal(map[string]string{"raw": raw})
	if err != nil {
		return fmt.Errorf("marshal payload: %w", err)
	}

	return resilience.Do(ctx, resilience.DefaultRetryConfig, resilience.IsRetryable, func() error {
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.endpoint, strings.NewReader(string(payload)))
		if err != nil {
			return fmt.Errorf("build request: %w", err)
		}
		req.Header.Set("Authorization", "Bearer "+s.accessToken)
		req.Header.Set("Content-Type", "application/json")

		resp, err := s.httpClient.Do(req)
		if err != nil {
			return fmt.Errorf("gmail request: %w", err)
		}
		defer resp.Body.Close()

		if resp.StatusCode != http.StatusOK {
			respBody, _ := io.ReadAll(resp.Body)
			return &resilience.HTTPStatusError{StatusCode: resp.StatusCode, Body: string(respBody)}
		}
		return nil
	})
}
