//nolint:testpackage // requires unexported gmail internals for testing
package google

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
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

	svc, err := NewService(context.Background(), tmp)
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
		t.Errorf("Unexpected snippet: %q", msg.Snippet)
	}
}

func TestNewService_Success(t *testing.T) {
	t.Parallel()
	tmp := t.TempDir()
	tok := storedToken{Token: "test-token", Expiry: time.Now().Add(1 * time.Hour)}
	tokData, _ := json.Marshal(tok) //nolint:gosec // G117: test token, no real secret
	_ = os.WriteFile(filepath.Join(tmp, "token.json"), tokData, 0o600)

	svc, err := NewService(context.Background(), tmp)
	if err != nil {
		t.Fatalf("NewService failed: %v", err)
	}
	if svc.accessToken != "test-token" {
		t.Errorf("want test-token, got %q", svc.accessToken)
	}
}

func TestNewService_Refresh(t *testing.T) {
	t.Parallel()
	const newTokenLiteral = "new-token"
	mux := http.NewServeMux()
	mux.HandleFunc("/token", func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"access_token": newTokenLiteral,
			"expires_in":   3600,
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
	tokenPath := filepath.Join(tmp, "token.json")
	_ = os.WriteFile(tokenPath, tokData, 0o600)

	svc, err := NewService(context.Background(), tmp)
	if err != nil {
		t.Fatalf("NewService failed: %v", err)
	}
	if svc.accessToken != newTokenLiteral {
		t.Errorf("want %s, got %q", newTokenLiteral, svc.accessToken)
	}

	data, _ := os.ReadFile(tokenPath)
	var updated storedToken
	_ = json.Unmarshal(data, &updated)
	if updated.Token != newTokenLiteral {
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

		_, err := NewService(context.Background(), tmp)
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

		_, err := NewService(context.Background(), tmp)
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
		err := svc.Send(ctx, "user@example.com", EmailContent{Subject: "Hello", Plain: "Body text"})
		if err != nil {
			t.Fatalf("Send failed: %v", err)
		}
	})

	t.Run("HTML", func(t *testing.T) {
		t.Parallel()
		err := svc.Send(ctx, "user@example.com", EmailContent{
			Subject: "Hello HTML",
			Plain:   "HTML Body",
			HTML:    "<html><body>HTML Body</body></html>",
		})
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
		err := svc.Send(context.Background(), "a@b.com", EmailContent{Subject: "s", Plain: "b"})
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
		err := svc.Send(context.Background(), "a@b.com", EmailContent{Subject: "s", Plain: "b"})
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

type gmailPageTransport func(*http.Request) (*http.Response, error)

func (f gmailPageTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

type gmailPageBody struct {
	io.Reader
	closed *bool
}

func (b gmailPageBody) Close() error { *b.closed = true; return nil }

//nolint:gocognit,cyclop // Table fixtures assert the complete request/response contract.
func TestSearchMessagesPagination(t *testing.T) {
	t.Parallel()
	fullPage := `{"messages":[` + strings.TrimSuffix(strings.Repeat(`{"id":"bulk"},`, 500), ",") + `],"nextPageToken":"last"}`
	bulkIDs := make([]string, 500, 501)
	for i := range bulkIDs {
		bulkIDs[i] = "bulk"
	}
	tests := []struct {
		name    string
		cap     int
		pages   []string
		tokens  []string
		counts  []string
		ids     []string
		wantErr string
	}{
		{"empty and short", 5, []string{`{"nextPageToken":"a +/&?="}`, `{"messages":[{"id":"1"}],"nextPageToken":"b"}`, `{"messages":[{"id":"2"}]}`}, []string{"", "a +/&?=", "b"}, []string{"5", "5", "4"}, []string{"1", "2"}, ""},
		{"cap", 2, []string{`{"messages":[{"id":"1"}],"nextPageToken":"a"}`, `{"messages":[{"id":"2"}],"nextPageToken":"unused"}`}, []string{"", "a"}, []string{"2", "1"}, []string{"1", "2"}, ""},
		{"oversized", 1, []string{`{"messages":[{"id":"1"},{"id":"2"}],"nextPageToken":"unused"}`}, []string{""}, []string{"1"}, []string{"1"}, ""},
		{"full API page", 501, []string{fullPage, `{"messages":[{"id":"last"}],"nextPageToken":"unused"}`}, []string{"", "last"}, []string{"500", "1"}, append(bulkIDs, "last"), ""},
		{"large cap", 501, []string{`{"messages":[{"id":"1"}],"nextPageToken":"a"}`, `{}`}, []string{"", "a"}, []string{"500", "500"}, []string{"1"}, ""},
		{"zero default", 0, []string{`{}`}, []string{""}, []string{"5"}, nil, ""},
		{"negative default", -1, []string{`{}`}, []string{""}, []string{"5"}, nil, ""},
		{"repeat", 5, []string{`{"nextPageToken":"a"}`, `{"nextPageToken":"a"}`}, []string{"", "a"}, []string{"5", "5"}, nil, "repeated"},
		{"alternating", 5, []string{`{"nextPageToken":"a"}`, `{"nextPageToken":"b"}`, `{"nextPageToken":"a"}`}, []string{"", "a", "b"}, []string{"5", "5", "5"}, nil, "repeated"},
		{"prefix cycle", 5, []string{`{"nextPageToken":"prefix"}`, `{"nextPageToken":"a"}`, `{"nextPageToken":"b"}`, `{"nextPageToken":"a"}`}, []string{"", "prefix", "a", "b"}, []string{"5", "5", "5", "5"}, nil, "repeated"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			calls := 0
			closed := true
			svc := &Service{baseURL: "https://example.test", httpClient: &http.Client{Transport: gmailPageTransport(func(r *http.Request) (*http.Response, error) {
				if !closed {
					t.Error("previous response still open")
				}
				closed = false
				i := calls
				calls++
				if i >= len(tt.pages) {
					return nil, fmt.Errorf("unexpected request")
				}
				q := r.URL.Query()
				if q.Get("q") != "from:a+b subject:hello &?=" || q.Get("pageToken") != tt.tokens[i] || q.Get("maxResults") != tt.counts[i] {
					t.Errorf("unexpected query: %v", q)
				}
				if i == 0 && q.Has("pageToken") {
					t.Error("initial pageToken present")
				}
				return &http.Response{StatusCode: 200, Body: gmailPageBody{strings.NewReader(tt.pages[i]), &closed}, Header: make(http.Header)}, nil
			})}}
			got, err := svc.SearchMessages(context.Background(), "from:a+b subject:hello &?=", tt.cap)
			if calls != len(tt.pages) || !closed {
				t.Errorf("calls=%d closed=%v", calls, closed)
			}
			if tt.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tt.wantErr) || got != nil {
					t.Fatalf("got %v, %v", got, err)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			var ids []string
			for _, m := range got {
				ids = append(ids, m.ID)
			}
			if !reflect.DeepEqual(ids, tt.ids) {
				t.Errorf("ids=%v want=%v", ids, tt.ids)
			}
		})
	}
}

//nolint:gocognit,cyclop // Fault-injection table keeps request state and failure assertions together.
func TestSearchMessagesLaterFailures(t *testing.T) {
	t.Parallel()
	const deadlineCase = "deadline"
	const distinctCase = "distinct cancellation"
	for _, kind := range []string{"http", "decode", "cancel", deadlineCase, distinctCase, "retry fresh state"} {
		t.Run(kind, func(t *testing.T) {
			t.Parallel()
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			calls := 0
			closed := true
			svc := &Service{baseURL: "https://example.test", httpClient: &http.Client{Transport: gmailPageTransport(func(r *http.Request) (*http.Response, error) {
				if !closed {
					t.Error("previous body open")
				}
				closed = false
				calls++
				body := `{"messages":[{"id":"first"}],"nextPageToken":"a"}`
				status := 200
				if calls > 1 {
					switch kind {
					case "http":
						status = 400
						body = "bad request"
					case "decode":
						body = `{"messages":false}`
					case "cancel":
						closed = true
						cancel()
						return nil, ctx.Err()
					case deadlineCase:
						closed = true
						return nil, context.DeadlineExceeded
					case distinctCase:
						body = fmt.Sprintf(`{"nextPageToken":"token%d"}`, calls)
						if calls == 4 {
							cancel()
						}
					case "retry fresh state":
						if calls == 2 {
							body = `{"messages":[{"id":"stale"}],"nextPageToken":"stale",`
						} else {
							body = `{}`
						}
					}
				}
				return &http.Response{StatusCode: status, Body: gmailPageBody{strings.NewReader(body), &closed}, Header: make(http.Header)}, nil
			})}}
			got, err := svc.SearchMessages(ctx, "query", 5)
			if !closed {
				t.Error("body left open")
			}
			if kind == "retry fresh state" {
				if err != nil || len(got) != 1 || got[0].ID != "first" || calls != 3 {
					t.Fatalf("got %v err=%v calls=%d", got, err, calls)
				}
				return
			}
			if err == nil || got != nil || !strings.Contains(err.Error(), "search messages") {
				t.Fatalf("got=%v err=%v", got, err)
			}
			if (kind == "cancel" || kind == distinctCase) && !errors.Is(err, context.Canceled) {
				t.Errorf("lost cancellation: %v", err)
			}
			if kind == deadlineCase && !errors.Is(err, context.DeadlineExceeded) {
				t.Errorf("lost deadline: %v", err)
			}
			wantCalls := 2
			if kind == distinctCase {
				wantCalls = 4
			}
			if kind == deadlineCase {
				wantCalls = 4
			}
			if calls != wantCalls {
				t.Errorf("calls=%d want=%d", calls, wantCalls)
			}
		})
	}
}

func TestSearchMessagesErrorPrivacy(t *testing.T) {
	t.Parallel()
	for _, status := range []int{0, http.StatusBadRequest} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			t.Parallel()
			svc := &Service{baseURL: "https://example.test", httpClient: &http.Client{Transport: gmailPageTransport(func(r *http.Request) (*http.Response, error) {
				if status == 0 {
					return nil, fmt.Errorf("transport unavailable")
				}
				return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader("private query and token")), Header: make(http.Header)}, nil
			})}}
			got, err := svc.SearchMessages(context.Background(), "private query and token", 5)
			if err == nil || got != nil || strings.Contains(err.Error(), "private") || strings.Contains(err.Error(), "pageToken") {
				t.Fatalf("got=%v err=%v", got, err)
			}
		})
	}
}
