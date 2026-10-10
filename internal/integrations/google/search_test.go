//nolint:testpackage // requires unexported search internals for testing
package google

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func TestExecuteSearch(t *testing.T) {
	t.Parallel()
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query().Get("q")
		if q == "error" {
			w.WriteHeader(http.StatusBadRequest)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"error": map[string]any{"message": "bad request"},
			})
			return
		}

		resp := SearchResponse{
			Items: []SearchResult{
				{Title: "Result 1", Link: "http://1", Snippet: "Snippet 1"},
			},
		}
		_ = json.NewEncoder(w).Encode(resp)
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)

	tests := []struct {
		name    string
		apiKey  string
		cx      string
		query   string
		wantErr bool
		errSub  string
	}{
		{
			name:   "Success",
			apiKey: "k",
			cx:     "c",
			query:  "q",
		},
		{
			name:    "APIError",
			apiKey:  "k",
			cx:      "c",
			query:   "error",
			wantErr: true,
			errSub:  "bad request",
		},
		{
			name:    "MissingParams",
			apiKey:  "",
			cx:      "",
			query:   "q",
			wantErr: true,
			errSub:  "apiKey and customCx are required",
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			svc := &SearchService{
				BaseURL:    server.URL,
				HTTPClient: http.DefaultClient,
			}
			res, err := svc.Execute(context.Background(), tt.apiKey, tt.cx, tt.query)
			if (err != nil) != tt.wantErr {
				t.Fatalf("Execute() error = %v, wantErr %v", err, tt.wantErr)
			}
			if tt.wantErr && tt.errSub != "" && !strings.Contains(err.Error(), tt.errSub) {
				t.Errorf("Execute() error = %v, want error containing %q", err, tt.errSub)
			}
			if !tt.wantErr && (len(res) != 1 || res[0].Title != "Result 1") {
				t.Errorf("Execute() unexpected results: %v", res)
			}
		})
	}
}

func TestFormatSearchMarkdown(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		results []SearchResult
		want    string
	}{
		{
			name: "WithResults",
			results: []SearchResult{
				{Title: "T1", Link: "L1", Snippet: "S1"},
			},
			want: "### Google Search Results",
		},
		{
			name:    "Empty",
			results: nil,
			want:    "No results found.",
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			out := FormatSearchMarkdown(tt.results)
			if !strings.Contains(out, tt.want) {
				t.Errorf("FormatSearchMarkdown() = %q, want it to contain %q", out, tt.want)
			}
		})
	}
}

type searchTransport func(*http.Request) (*http.Response, error)

func (f searchTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

type searchBrokenBody struct{ err error }

func (b searchBrokenBody) Read([]byte) (int, error) { return 0, b.err }
func (searchBrokenBody) Close() error               { return nil }

//nolint:gocognit,cyclop // Table exercises independent failure stages and their offline transports.
func TestSearchErrorBoundary(t *testing.T) {
	t.Parallel()
	const key = "synthetic/key+ secret"
	sentinel := errors.New("offline sentinel")
	tests := []struct {
		name, stage, base string
		status            int
		body              string
		cause             error
		redirect          bool
	}{
		{name: "transport echo", stage: "transport", cause: sentinel},
		{name: "redirect policy", stage: "redirect", redirect: true, cause: sentinel},
		{name: "malformed URL", stage: "create search request", base: "://bad"},
		{name: "read echo", stage: "read response", cause: sentinel, status: 200},
		{name: "decode", stage: "decode", status: 200, body: "not JSON"},
		{name: "API message echo", stage: "google API 403", status: 403, body: "message"},
		{name: "API body echo", stage: "google API 502", status: 502, body: "raw"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			base := "https://search.invalid/search"
			if tt.base != "" {
				base = tt.base
			}
			client := &http.Client{Transport: searchTransport(func(r *http.Request) (*http.Response, error) {
				echo := fmt.Errorf("request %s: %w", r.URL, tt.cause)
				if tt.redirect {
					return &http.Response{StatusCode: 302, Header: http.Header{"Location": {r.URL.String() + "&redirect=1"}}, Body: http.NoBody}, nil
				}
				if tt.status == 0 {
					return nil, echo
				}
				body := io.NopCloser(strings.NewReader(tt.body))
				if tt.name == "read echo" {
					body = searchBrokenBody{echo}
				}
				if tt.body == "message" {
					data, _ := json.Marshal(map[string]any{"error": map[string]string{"message": r.URL.String() + key}})
					body = io.NopCloser(strings.NewReader(string(data)))
				}
				if tt.body == "raw" {
					body = io.NopCloser(strings.NewReader(r.URL.String() + key))
				}
				return &http.Response{StatusCode: tt.status, Body: body}, nil
			}), CheckRedirect: func(r *http.Request, _ []*http.Request) error { return fmt.Errorf("redirect %s: %w", r.URL, sentinel) }}
			_, err := (&SearchService{BaseURL: base, HTTPClient: client}).Execute(context.Background(), key, "cx", "query")
			if err == nil || !strings.Contains(err.Error(), tt.stage) {
				t.Fatalf("missing safe stage: %v", err)
			}
			for _, secret := range []string{key, url.QueryEscape(key), "https://search.invalid", "key="} {
				if strings.Contains(err.Error(), secret) {
					t.Fatalf("disclosed %q: %v", secret, err)
				}
			}
			if tt.cause != nil && !errors.Is(err, sentinel) {
				t.Fatalf("lost sentinel: %v", err)
			}
		})
	}
}

//nolint:gocognit // Verify identity, timeout classification and caller ownership together.
func TestSearchErrorClassification(t *testing.T) {
	t.Parallel()
	for _, cause := range []error{context.Canceled, context.DeadlineExceeded, &net.DNSError{IsTimeout: true}} {
		t.Run(fmt.Sprintf("%T/%v", cause, cause), func(t *testing.T) {
			t.Parallel()
			original := &url.Error{Op: "Get", URL: "https://search.invalid?key=synthetic", Err: cause}
			client := &http.Client{Transport: searchTransport(func(*http.Request) (*http.Response, error) { return nil, original })}
			_, err := (&SearchService{BaseURL: "https://search.invalid", HTTPClient: client}).Execute(context.Background(), "synthetic", "cx", "q")
			if !errors.Is(err, cause) {
				t.Fatalf("lost cause: %v", err)
			}
			var timeout net.Error
			if errors.As(cause, &timeout) {
				var got net.Error
				if !errors.As(err, &got) || !got.Timeout() {
					t.Fatal("lost timeout classification")
				}
			}
			if original.URL != "https://search.invalid?key=synthetic" || !errors.Is(original.Err, cause) {
				t.Fatal("mutated caller error")
			}
		})
	}
}

func TestSafeSearchErrorOwnership(t *testing.T) {
	t.Parallel()
	original := &url.Error{Op: "Get", URL: "https://search.invalid?key=synthetic", Err: errors.New("offline")}
	err := safeSearchError("search request: transport failure", original)
	var copied *url.Error
	if !errors.As(err, &copied) || copied == original || copied.URL != "[redacted]" {
		t.Fatalf("missing sanitized copy: %v", err)
	}
	if original.URL != "https://search.invalid?key=synthetic" {
		t.Fatal("mutated original")
	}
	var classification net.Error
	if !errors.As(err, &classification) || classification.Timeout() || (&searchError{cause: original}).Temporary() {
		t.Fatal("ordinary error classified as temporary timeout")
	}
}
