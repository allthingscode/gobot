package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/integrations/google"
)

func TestWebSearchTool(t *testing.T) {
	// Mock Google Search API
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		key := r.URL.Query().Get("key")
		cx := r.URL.Query().Get("cx")
		query := r.URL.Query().Get("q")

		if key != "test-key" || cx != "test-cx" {
			w.WriteHeader(http.StatusUnauthorized)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"error": map[string]any{"message": "invalid key or cx"},
			})
			return
		}

		if query == "empty" {
			_ = json.NewEncoder(w).Encode(google.SearchResponse{Items: []google.SearchResult{}})
			return
		}

		resp := google.SearchResponse{
			Items: []google.SearchResult{
				{
					Title:   "Gobot GitHub",
					Link:    "https://github.com/allthingscode/gobot",
					Snippet: "Go-native strategic agent.",
				},
				{
					Title:   "Golang Home",
					Link:    "https://go.dev",
					Snippet: "Build simple, secure, and maintainable systems.",
				},
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
		args    map[string]any
		wantErr bool
		errSub  string
		wantSub string
	}{
		{
			name:   "BasicSearch",
			apiKey: "test-key",
			cx:     "test-cx",
			args:   map[string]any{"query": "gobot"},
			wantSub: "Gobot GitHub",
		},
		{
			name:   "EmptyResults",
			apiKey: "test-key",
			cx:     "test-cx",
			args:   map[string]any{"query": "empty"},
			wantSub: "No results found.",
		},
		{
			name:    "MissingQuery",
			apiKey:  "test-key",
			cx:      "test-cx",
			args:    map[string]any{},
			wantErr: true,
			errSub:  "query is required",
		},
		{
			name:    "InvalidAuth",
			apiKey:  "bad-key",
			cx:      "bad-cx",
			args:    map[string]any{"query": "any"},
			wantErr: true,
			errSub:  "invalid key or cx",
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			tool := newWebSearchTool(tt.apiKey, tt.cx)
			tool.baseURL = server.URL // Override for testing

			res, err := tool.Execute(context.Background(), "test-session", tt.args)
			if (err != nil) != tt.wantErr {
				t.Fatalf("Execute() error = %v, wantErr %v", err, tt.wantErr)
			}
			if tt.wantErr && tt.errSub != "" && !strings.Contains(err.Error(), tt.errSub) {
				t.Errorf("Execute() error = %v, want error containing %q", err, tt.errSub)
			}
			if !tt.wantErr && tt.wantSub != "" && !strings.Contains(res, tt.wantSub) {
				t.Errorf("Execute() = %q, want it to contain %q", res, tt.wantSub)
			}
		})
	}
}
