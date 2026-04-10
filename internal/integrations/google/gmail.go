// package google provides OAuth2 token management and email delivery via the Gmail API.
// It uses only the standard library and the internal reporter package — no Google SDK required.
package google

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

const (
	gmailBaseURL = "https://gmail.googleapis.com/gmail/v1/users/me"
)

var timeoutClient = &http.Client{Timeout: 30 * time.Second}

// storedToken mirrors the JSON structure written by google-auth-library (Python).

// MessageSummary represents a minimal message object from a list/search result.
type MessageSummary struct {
	ID       string `json:"id"`
	ThreadID string `json:"threadId"`
}

// Message represents a full Gmail message.
type Message struct {
	ID           string   `json:"id"`
	ThreadID     string   `json:"threadId"`
	Snippet      string   `json:"snippet"`
	InternalDate string   `json:"internalDate"`
	Payload      *Payload `json:"payload"`
}

type Payload struct {
	Headers []Header `json:"headers"`
	Body    *Body    `json:"body"`
	Parts   []Part   `json:"parts"`
}

type Header struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

type Body struct {
	Size int    `json:"size"`
	Data string `json:"data"` // Base64 encoded
}

type Part struct {
	MimeType string   `json:"mimeType"`
	Body     *Body    `json:"body"`
	Parts    []Part   `json:"parts"`
	Filename string   `json:"filename"`
	Headers  []Header `json:"headers"`
}

// Service provides access to the Gmail API.
type Service struct {
	accessToken string
	baseURL     string
	httpClient  *http.Client
}

// NewService loads OAuth2 credentials from {secretsRoot}/token.json and returns a Service.
func NewService(secretsRoot string) (*Service, error) {
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
		if updated, err := json.Marshal(tok); err == nil {
			_ = os.WriteFile(tokenPath, updated, 0o600)
		}
	}

	return &Service{
		accessToken: tok.Token,
		baseURL:     gmailBaseURL,
		httpClient:  timeoutClient,
	}, nil
}

// Send delivers an email via the Gmail API.
func (s *Service) Send(ctx context.Context, to, subject, body string) error {
	wrapped := reporter.WrapHTML(body)
	isHTML := wrapped != body
	const multipartBoundary = "gobot_alt_20260328"

	var sb strings.Builder
	sb.WriteString("To: " + to + "\r\n")
	sb.WriteString("Subject: " + mime.QEncoding.Encode("UTF-8", subject) + "\r\n")
	sb.WriteString("MIME-Version: 1.0\r\n")

	if isHTML {
		plainText := reporter.StripHTML(wrapped)
		sb.WriteString("Content-Type: multipart/alternative; boundary=\"" + multipartBoundary + "\"\r\n")
		sb.WriteString("\r\n")
		sb.WriteString("--" + multipartBoundary + "\r\n")
		sb.WriteString("Content-Type: text/plain; charset=UTF-8\r\n\r\n")
		sb.WriteString(plainText + "\r\n\r\n")
		sb.WriteString("--" + multipartBoundary + "\r\n")
		sb.WriteString("Content-Type: text/html; charset=UTF-8\r\n\r\n")
		sb.WriteString(wrapped + "\r\n\r\n")
		sb.WriteString("--" + multipartBoundary + "--\r\n")
	} else {
		sb.WriteString("Content-Type: text/plain; charset=UTF-8\r\n\r\n")
		sb.WriteString(body)
	}

	raw := base64.URLEncoding.EncodeToString([]byte(sb.String()))
	payload, _ := json.Marshal(map[string]string{"raw": raw})

	endpoint := s.baseURL + "/messages/send"
	return resilience.Do(ctx, resilience.DefaultRetryConfig, resilience.IsRetryable, func() error {
		req, _ := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(string(payload)))
		req.Header.Set("Authorization", "Bearer "+s.accessToken)
		req.Header.Set("Content-Type", "application/json")
		resp, err := s.httpClient.Do(req)
		if err != nil {
			return err
		}
		defer func() { _ = resp.Body.Close() }()
		if resp.StatusCode != http.StatusOK {
			b, _ := io.ReadAll(resp.Body)
			return &resilience.HTTPStatusError{StatusCode: resp.StatusCode, Body: string(b)}
		}
		return nil
	})
}

// SearchMessages searches for messages matching the query.
func (s *Service) SearchMessages(ctx context.Context, query string, maxResults int) ([]MessageSummary, error) {
	u, _ := url.Parse(s.baseURL + "/messages")
	q := u.Query()
	q.Set("q", query)
	if maxResults > 0 {
		q.Set("maxResults", fmt.Sprintf("%d", maxResults))
	}
	u.RawQuery = q.Encode()

	var result struct {
		Messages []MessageSummary `json:"messages"`
	}

	err := resilience.Do(ctx, resilience.DefaultRetryConfig, resilience.IsRetryable, func() error {
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), http.NoBody)
		req.Header.Set("Authorization", "Bearer "+s.accessToken)
		resp, err := s.httpClient.Do(req)
		if err != nil {
			return err
		}
		defer func() { _ = resp.Body.Close() }()
		if resp.StatusCode != http.StatusOK {
			b, _ := io.ReadAll(resp.Body)
			return &resilience.HTTPStatusError{StatusCode: resp.StatusCode, Body: string(b)}
		}
		return json.NewDecoder(resp.Body).Decode(&result)
	})

	return result.Messages, err
}

// GetMessage retrieves a full message by ID.
func (s *Service) GetMessage(ctx context.Context, id string) (*Message, error) {
	endpoint := s.baseURL + "/messages/" + id

	var msg Message
	err := resilience.Do(ctx, resilience.DefaultRetryConfig, resilience.IsRetryable, func() error {
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, http.NoBody)
		req.Header.Set("Authorization", "Bearer "+s.accessToken)
		resp, err := s.httpClient.Do(req)
		if err != nil {
			return err
		}
		defer func() { _ = resp.Body.Close() }()
		if resp.StatusCode != http.StatusOK {
			b, _ := io.ReadAll(resp.Body)
			return &resilience.HTTPStatusError{StatusCode: resp.StatusCode, Body: string(b)}
		}
		return json.NewDecoder(resp.Body).Decode(&msg)
	})

	return &msg, err
}

// GetHeader returns the value of the named header.
func (m *Message) GetHeader(name string) string {
	if m.Payload == nil {
		return ""
	}
	for _, h := range m.Payload.Headers {
		if strings.EqualFold(h.Name, name) {
			return h.Value
		}
	}
	return ""
}

// ExtractBody attempts to find and decode the plain text body of the message.
func (m *Message) ExtractBody() string {
	if m.Payload == nil {
		return ""
	}
	return extractBodyFromParts(m.Payload.Parts, m.Payload.Body)
}

func extractBodyFromParts(parts []Part, body *Body) string {
	// If there's a body at this level, use it if it's not empty
	if body != nil && body.Data != "" {
		data, err := base64.URLEncoding.DecodeString(body.Data)
		if err == nil {
			return string(data)
		}
	}

	// Prefer text/plain over text/html
	for _, p := range parts {
		if p.MimeType == "text/plain" && p.Body != nil && p.Body.Data != "" {
			data, err := base64.URLEncoding.DecodeString(p.Body.Data)
			if err == nil {
				return string(data)
			}
		}
	}

	// Recurse into parts
	for _, p := range parts {
		if p.MimeType == "multipart/alternative" || p.MimeType == "multipart/mixed" {
			if b := extractBodyFromParts(p.Parts, p.Body); b != "" {
				return b
			}
		}
	}

	return ""
}
