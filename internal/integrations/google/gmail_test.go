//nolint:testpackage // requires unexported gmail internals for testing
package google

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestGmailSearchAndRead(t *testing.T) {
	t.Parallel()
	server := setupGmailSearchMockServer(t)
	t.Cleanup(server.Close)

	svc := setupGmailService(t, server.URL)
	ctx := context.Background()

	t.Run("Search", func(t *testing.T) {
		t.Parallel()
		validateGmailSearch(t, svc, ctx)
	})

	t.Run("Get", func(t *testing.T) {
		t.Parallel()
		validateGmailGet(t, svc, ctx)
	})
}

func setupGmailSearchMockServer(t *testing.T) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/messages", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("q") == "empty" {
			_ = json.NewEncoder(w).Encode(map[string]any{"messages": []any{}})
			return
		}
		_ = json.NewEncoder(w).Encode(struct {
			Messages []MessageSummary `json:"messages"`
		}{
			Messages: []MessageSummary{{ID: "msg123", ThreadID: "thread123"}},
		})
	})
	mux.HandleFunc("/messages/msg123", func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(Message{
			ID:      "msg123",
			Snippet: "Hello world snippet",
			Payload: &Payload{
				Headers: []Header{
					{Name: "Subject", Value: "Test Subject"},
					{Name: "From", Value: "sender@example.com"},
				},
				Body: &Body{
					Data: base64.URLEncoding.EncodeToString([]byte("Full body text")),
				},
			},
		})
	})
	return httptest.NewServer(mux)
}

func setupGmailService(t *testing.T, baseURL string) *Service {
	t.Helper()
	tmp := t.TempDir()
	tok := storedToken{Token: "fake-token", Expiry: time.Now().Add(1 * time.Hour)}
	tokData, _ := json.Marshal(tok) //nolint:gosec // G117: test token, no real secret
	_ = os.WriteFile(filepath.Join(tmp, "token.json"), tokData, 0o600)

	svc, err := NewService(tmp)
	if err != nil {
		t.Fatalf("NewService failed: %v", err)
	}
	svc.baseURL = baseURL
	return svc
}

func validateGmailSearch(t *testing.T, svc *Service, ctx context.Context) {
	t.Helper()
	res, err := svc.SearchMessages(ctx, "query", 5)
	if err != nil {
		t.Fatalf("Search failed: %v", err)
	}
	if len(res) != 1 || res[0].ID != "msg123" {
		t.Errorf("Unexpected search results: %+v", res)
	}
}

func validateGmailGet(t *testing.T, svc *Service, ctx context.Context) {
	t.Helper()
	msg, err := svc.GetMessage(ctx, "msg123")
	if err != nil {
		t.Fatalf("GetMessage failed: %v", err)
	}
	if msg.Snippet != "Hello world snippet" {
		t.Errorf("Unexpected snippet: %s", msg.Snippet)
	}
	if msg.GetHeader("Subject") != "Test Subject" {
		t.Errorf("Unexpected subject: %s", msg.GetHeader("Subject"))
	}
	if msg.ExtractBody() != "Full body text" {
		t.Errorf("Unexpected body: %s", msg.ExtractBody())
	}
}

func TestNewService_Refresh(t *testing.T) {
	t.Parallel()
	refreshCalled := false
	mux := http.NewServeMux()
	mux.HandleFunc("/token", func(w http.ResponseWriter, _ *http.Request) {
		refreshCalled = true
		_ = json.NewEncoder(w).Encode(map[string]any{
			"access_token": "new-token",
			"expires_in":   3600,
		})
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)

	tmp := t.TempDir()
	tok := storedToken{
		Token:        "expired-token",
		RefreshToken: "refresh-me",
		TokenURI:     server.URL + "/token",
		Expiry:       time.Now().Add(-1 * time.Hour),
	}
	tokData, _ := json.Marshal(tok) //nolint:gosec // G117: test token, no real secret
	_ = os.WriteFile(filepath.Join(tmp, "token.json"), tokData, 0o600)

	svc, err := NewService(tmp)
	if err != nil {
		t.Fatalf("NewService with refresh failed: %v", err)
	}

	if !refreshCalled {
		t.Error("expected token refresh to be called")
	}
	if svc.accessToken != "new-token" { //nolint:goconst // test fixture token
		t.Errorf("expected new-token, got %s", svc.accessToken)
	}

	// Verify file was updated
	data, _ := os.ReadFile(filepath.Join(tmp, "token.json"))
	var updated storedToken
	_ = json.Unmarshal(data, &updated)
	if updated.Token != "new-token" {
		t.Errorf("token.json not updated with new token")
	}
}

func TestNewService_RefreshError(t *testing.T) {
	t.Parallel()

	t.Run("InvalidGrant", func(t *testing.T) {
		t.Parallel()
		mux := http.NewServeMux()
		mux.HandleFunc("/token", func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusBadRequest)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"error": "invalid_grant",
			})
		})
		server := httptest.NewServer(mux)
		t.Cleanup(server.Close)

		tmp := t.TempDir()
		tok := storedToken{
			RefreshToken: "refresh-me",
			TokenURI:     server.URL + "/token",
			Expiry:       time.Now().Add(-1 * time.Hour),
		}
		tokData, _ := json.Marshal(tok) //nolint:gosec // G117: test token, no real secret
		_ = os.WriteFile(filepath.Join(tmp, "token.json"), tokData, 0o600)

		_, err := NewService(tmp)
		if err == nil || !strings.Contains(err.Error(), "AUTH_EXPIRED") {
			t.Errorf("expected ErrNeedsReauth (AUTH_EXPIRED), got %v", err)
		}
	})

	t.Run("MalformedJSON", func(t *testing.T) {
		t.Parallel()
		mux := http.NewServeMux()
		mux.HandleFunc("/token", func(w http.ResponseWriter, _ *http.Request) {
			_, _ = w.Write([]byte("not json"))
		})
		server := httptest.NewServer(mux)
		t.Cleanup(server.Close)

		tmp := t.TempDir()
		tok := storedToken{
			RefreshToken: "refresh-me",
			TokenURI:     server.URL + "/token",
			Expiry:       time.Now().Add(-1 * time.Hour),
		}
		tokData, _ := json.Marshal(tok) //nolint:gosec // G117: test token, no real secret
		_ = os.WriteFile(filepath.Join(tmp, "token.json"), tokData, 0o600)

		_, err := NewService(tmp)
		if err == nil || !strings.Contains(err.Error(), "invalid token refresh response") {
			t.Errorf("expected JSON unmarshal error, got %v", err)
		}
	})
}

func TestGmailSend(t *testing.T) {
	t.Parallel()
	server := setupGmailSendMockServer(t)
	t.Cleanup(server.Close)

	svc := &Service{
		accessToken: "fake-token",
		baseURL:     server.URL,
		httpClient:  server.Client(),
	}

	ctx := context.Background()

	t.Run("PlainText", func(t *testing.T) {
		t.Parallel()
		err := svc.Send(ctx, "user@example.com", "Hello", "Body text")
		if err != nil {
			t.Fatalf("Send failed: %v", err)
		}
	})

	t.Run("HTML", func(t *testing.T) {
		t.Parallel()
		err := svc.Send(ctx, "user@example.com", "Hello HTML", "<html><body>HTML Body</body></html>")
		if err != nil {
			t.Fatalf("Send HTML failed: %v", err)
		}
	})
}

func setupGmailSendMockServer(t *testing.T) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		var payload struct {
			Raw string `json:"raw"`
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		validateGmailSendPayload(t, w, payload.Raw)
	}))
}

func validateGmailSendPayload(t *testing.T, w http.ResponseWriter, rawPayload string) {
	t.Helper()
	raw, _ := base64.URLEncoding.DecodeString(rawPayload)
	sraw := string(raw)

	if !strings.Contains(sraw, "To: user@example.com") {
		http.Error(w, "missing to", http.StatusBadRequest)
		return
	}

	// Check for multipart structure in HTML sends
	if strings.Contains(sraw, "Subject: Hello HTML") {
		if !strings.Contains(sraw, "Content-Type: multipart/alternative") || !strings.Contains(sraw, "boundary=\"gobot_alt_20260328\"") {
			http.Error(w, "invalid HTML send structure", http.StatusBadRequest)
			return
		}
	}

	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]string{"id": "sent123"})
}

func TestGmailErrors(t *testing.T) {
	t.Parallel()

	t.Run("RetryableError", func(t *testing.T) {
		t.Parallel()
		calls := 0
		mux := http.NewServeMux()
		mux.HandleFunc("/messages/send", func(w http.ResponseWriter, _ *http.Request) {
			calls++
			if calls == 1 {
				w.WriteHeader(http.StatusInternalServerError)
				return
			}
			w.WriteHeader(http.StatusOK)
			_ = json.NewEncoder(w).Encode(map[string]string{"id": "ok"})
		})
		server := httptest.NewServer(mux)
		t.Cleanup(server.Close)

		svc := &Service{baseURL: server.URL, httpClient: server.Client()}
		err := svc.Send(context.Background(), "a@b.com", "s", "b")
		if err != nil {
			t.Errorf("expected success after retry, got %v", err)
		}
		if calls != 2 {
			t.Errorf("expected 2 calls, got %d", calls)
		}
	})

	t.Run("NonRetryableError", func(t *testing.T) {
		t.Parallel()
		mux := http.NewServeMux()
		mux.HandleFunc("/messages/send", func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte("bad request data"))
		})
		server := httptest.NewServer(mux)
		t.Cleanup(server.Close)

		svc := &Service{baseURL: server.URL, httpClient: server.Client()}
		err := svc.Send(context.Background(), "a@b.com", "s", "b")
		if err == nil {
			t.Error("expected error, got nil")
		}
		if !strings.Contains(err.Error(), "bad request data") {
			t.Errorf("expected error to contain body, got %v", err)
		}
	})
}

func TestExtractBodyFromParts(t *testing.T) {
	t.Parallel()
	type tc struct {
		name     string
		payload  *Payload
		wantBody string
	}
	plain := func(s string) *Body { return &Body{Data: base64.URLEncoding.EncodeToString([]byte(s))} }
	part := func(mime, body string) Part { return Part{MimeType: mime, Body: plain(body)} }
	text := "text/plain"
	alt := "multipart/alternative"
	appPdf := "application/pdf"
	tests := []tc{
		{"Simple", &Payload{Body: plain("Simple body")}, "Simple body"},
		{"TextPrefer", &Payload{Parts: []Part{part(text, "Plain text"), {MimeType: "text/html", Body: plain("<p>HTML</p>")}}}, "Plain text"},
		{"Nested", &Payload{Parts: []Part{{MimeType: alt, Parts: []Part{part(text, "Nested plain text")}}}}, "Nested plain text"},
		{"Mixed", &Payload{Parts: []Part{{MimeType: alt, Parts: []Part{part(text, "Mixed body text")}}, {MimeType: appPdf, Filename: "test.pdf", Body: &Body{Data: "SOMEBASE64DATA"}}}}, "Mixed body text"},
		{"Empty", &Payload{Body: &Body{Data: ""}}, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got := (&Message{Payload: tt.payload}).ExtractBody()
			if !strings.Contains(got, tt.wantBody) {
				t.Errorf("got %q, want %q", got, tt.wantBody)
			}
		})
	}
}
