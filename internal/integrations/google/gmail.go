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

	"github.com/allthingscode/gobot/internal/resilience"
	"github.com/allthingscode/gobot/internal/state"
)

// ErrNeedsReauth is returned when the OAuth2 token is expired and cannot be refreshed
// automatically (missing refresh token or invalid_grant from the token endpoint).
// The caller should direct the user to run `gobot reauth`.
var ErrNeedsReauth = errors.New("AUTH_EXPIRED: run gobot reauth")

const (
	gmailBaseURL = "https://gmail.googleapis.com/gmail/v1/users/me"
)

// EmailContent represents the subject and body (plain and/or HTML) of an email.
type EmailContent struct {
	Subject string
	Plain   string
	HTML    string
}

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
	MimeType string   `json:"mimeType"`
	Headers  []Header `json:"headers"`
	Body     *Body    `json:"body"`
	Parts    []Part   `json:"parts"`
}

type Header struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

type Body struct {
	AttachmentID string `json:"attachmentId"`
	Size         int    `json:"size"`
	Data         string `json:"data"` // Base64 encoded
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
func NewService(ctx context.Context, secretsRoot string) (*Service, error) {
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
		if err := refreshToken(ctx, &tok, TimeoutClient); err != nil {
			if strings.Contains(err.Error(), "invalid_grant") {
				return nil, ErrNeedsReauth
			}
			return nil, fmt.Errorf("token refresh failed: %w", err)
		}
		if updated, err := json.Marshal(tok); err == nil { //nolint:gosec // G117: RefreshToken must be marshaled to persist the token
			_ = state.WriteFileAtomic(tokenPath, updated, 0o600)
		}
	}

	return &Service{
		accessToken: tok.Token,
		baseURL:     gmailBaseURL,
		httpClient:  TimeoutClient,
	}, nil
}

// Send delivers an email via the Gmail API.
func (s *Service) Send(ctx context.Context, to string, content EmailContent) error {
	isHTML := content.HTML != ""
	const multipartBoundary = "gobot_alt_20260328"

	var sb strings.Builder
	sb.WriteString("To: " + to + "\r\n")
	sb.WriteString("Subject: " + mime.QEncoding.Encode("UTF-8", content.Subject) + "\r\n")
	sb.WriteString("MIME-Version: 1.0\r\n")

	if isHTML {
		sb.WriteString("Content-Type: multipart/alternative; boundary=\"" + multipartBoundary + "\"\r\n")
		sb.WriteString("\r\n")
		sb.WriteString("--" + multipartBoundary + "\r\n")
		sb.WriteString("Content-Type: text/plain; charset=UTF-8\r\n\r\n")
		sb.WriteString(content.Plain + "\r\n\r\n")
		sb.WriteString("--" + multipartBoundary + "\r\n")
		sb.WriteString("Content-Type: text/html; charset=UTF-8\r\n\r\n")
		sb.WriteString(content.HTML + "\r\n\r\n")
		sb.WriteString("--" + multipartBoundary + "--\r\n")
	} else {
		sb.WriteString("Content-Type: text/plain; charset=UTF-8\r\n\r\n")
		sb.WriteString(content.Plain)
	}

	raw := base64.URLEncoding.EncodeToString([]byte(sb.String()))
	payload, _ := json.Marshal(map[string]string{"raw": raw})

	endpoint := s.baseURL + "/messages/send"
	if err := resilience.Do(ctx, resilience.DefaultRetryConfig, resilience.IsRetryable, func() error {
		req, _ := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(string(payload)))
		req.Header.Set("Authorization", "Bearer "+s.accessToken)
		req.Header.Set("Content-Type", "application/json")
		resp, err := s.httpClient.Do(req)
		if err != nil {
			return fmt.Errorf("http send: %w", err)
		}
		defer func() { _ = resp.Body.Close() }()
		if resp.StatusCode != http.StatusOK {
			b, _ := io.ReadAll(resp.Body)
			return &resilience.HTTPStatusError{StatusCode: resp.StatusCode, Body: string(b)}
		}
		return nil
	}); err != nil {
		return fmt.Errorf("send email: %w", err)
	}
	return nil
}

// SearchMessages searches for messages matching the query.
func (s *Service) SearchMessages(ctx context.Context, query string, maxResults int) ([]MessageSummary, error) {
	if maxResults <= 0 {
		maxResults = 5
	}
	u, err := url.Parse(s.baseURL + "/messages")
	if err != nil {
		return nil, fmt.Errorf("search messages URL: %w", err)
	}
	var messages []MessageSummary
	seen := make(map[string]bool)
	q := u.Query()
	q.Set("q", query)
	q.Del("pageToken")
	for {
		if err := ctx.Err(); err != nil {
			return nil, fmt.Errorf("search messages: %w", err)
		}
		remaining := maxResults - len(messages)
		q.Set("maxResults", fmt.Sprintf("%d", min(500, remaining)))
		u.RawQuery = q.Encode()
		page, err := s.searchMessagesPage(ctx, u.String())
		if err != nil {
			return nil, fmt.Errorf("search messages: %w", err)
		}
		if err := ctx.Err(); err != nil {
			return nil, fmt.Errorf("search messages: %w", err)
		}
		messages = append(messages, page.Messages[:min(remaining, len(page.Messages))]...)
		if len(messages) == maxResults || page.NextPageToken == "" {
			return messages, nil
		}
		token := page.NextPageToken
		if seen[token] {
			return nil, fmt.Errorf("search messages: repeated continuation token")
		}
		seen[token] = true
		q.Set("pageToken", token)
	}
}

type gmailSearchPage struct {
	Messages      []MessageSummary `json:"messages"`
	NextPageToken string           `json:"nextPageToken"`
}

func (s *Service) searchMessagesPage(ctx context.Context, endpoint string) (gmailSearchPage, error) {
	var page gmailSearchPage
	err := resilience.Do(ctx, resilience.DefaultRetryConfig, resilience.IsRetryable, func() error {
		page = gmailSearchPage{}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, http.NoBody)
		if err != nil {
			return fmt.Errorf("search request: %w", err)
		}
		req.Header.Set("Authorization", "Bearer "+s.accessToken)
		resp, err := s.httpClient.Do(req)
		if err != nil {
			// The retry logger must not expose the request query or token.
			var urlErr *url.Error
			if errors.As(err, &urlErr) {
				err = urlErr.Err
			}
			return fmt.Errorf("http search: %w", err)
		}
		defer func() { _ = resp.Body.Close() }()
		if resp.StatusCode != http.StatusOK {
			// Retry logging must not include server-echoed query or message content.
			return &resilience.HTTPStatusError{StatusCode: resp.StatusCode}
		}
		if err := json.NewDecoder(resp.Body).Decode(&page); err != nil {
			return fmt.Errorf("decode search page: %w", err)
		}
		return nil
	})
	if err != nil {
		return gmailSearchPage{}, fmt.Errorf("search page: %w", err)
	}
	return page, nil
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
			return fmt.Errorf("http get: %w", err)
		}
		defer func() { _ = resp.Body.Close() }()
		if resp.StatusCode != http.StatusOK {
			b, _ := io.ReadAll(resp.Body)
			return &resilience.HTTPStatusError{StatusCode: resp.StatusCode, Body: string(b)}
		}
		return json.NewDecoder(resp.Body).Decode(&msg)
	})
	if err != nil {
		return nil, fmt.Errorf("get message: %w", err)
	}

	return &msg, nil
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

// ErrPlainTextUnavailable indicates that no inline plain-text body can be read.
var ErrPlainTextUnavailable = errors.New("plain-text body unavailable")

// ExtractPlainText returns the first readable nonempty inline plain-text body.
// Decode errors and unavailable candidates take precedence over empty candidates.
func (m *Message) ExtractPlainText() (string, error) {
	if m == nil || m.Payload == nil {
		return "", fmt.Errorf("extract plain text: %w", ErrPlainTextUnavailable)
	}
	result := plainTextResult{}
	p := m.Payload
	mediaType := p.MimeType
	if mediaType == "" {
		mediaType = plainTextMIME
		if len(p.Parts) != 0 {
			mediaType = "multipart/mixed"
		}
	}
	if text, ok := result.visit(mediaType, "", p.Body, p.Parts); ok {
		return text, nil
	}
	if result.decodeErr != nil {
		return "", result.decodeErr
	}
	if result.unavailable || !result.empty {
		return "", fmt.Errorf("extract plain text: %w", ErrPlainTextUnavailable)
	}
	return "", nil
}

// ExtractBody preserves the string-only interface for existing callers.
func (m *Message) ExtractBody() string {
	text, err := m.ExtractPlainText()
	if err != nil {
		return ""
	}
	return text
}

const plainTextMIME = "text/plain"

type plainTextResult struct {
	decodeErr   error
	unavailable bool
	empty       bool
}

func (r *plainTextResult) visit(mediaType, filename string, body *Body, parts []Part) (string, bool) {
	if filename != "" {
		return "", false
	}
	mediaType, _, err := mime.ParseMediaType(mediaType)
	if err != nil {
		return "", false
	}
	if strings.HasPrefix(mediaType, "multipart/") {
		for _, part := range parts {
			if text, ok := r.visit(part.MimeType, part.Filename, part.Body, part.Parts); ok {
				return text, true
			}
		}
		return "", false
	}
	if mediaType != plainTextMIME || len(parts) != 0 {
		return "", false
	}
	return r.decode(body)
}

func (r *plainTextResult) decode(body *Body) (string, bool) {
	if body == nil || body.AttachmentID != "" || (body.Data == "" && body.Size != 0) {
		r.unavailable = true
		return "", false
	}
	data, err := base64.URLEncoding.DecodeString(body.Data)
	if err != nil && !strings.Contains(body.Data, "=") {
		data, err = base64.RawURLEncoding.DecodeString(body.Data)
	}
	if err != nil {
		if r.decodeErr == nil {
			r.decodeErr = fmt.Errorf("decode plain-text body: %w", err)
		}
		return "", false
	}
	if len(data) == 0 {
		r.empty = true
		return "", false
	}
	return string(data), true
}
