package google

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
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
