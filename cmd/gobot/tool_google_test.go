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
	t.Parallel()
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
			name:    "BasicSearch",
			apiKey:  "test-key",
			cx:      "test-cx",
			args:    map[string]any{"query": "gobot"},
			wantSub: "Gobot GitHub",
		},
		{
			name:    "EmptyResults",
			apiKey:  "test-key",
			cx:      "test-cx",
			args:    map[string]any{"query": "empty"},
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

			res, err := tool.Execute(context.Background(), "test-session", "", tt.args)
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

func TestCompleteTaskTool_Name(t *testing.T) {
	t.Parallel()
	tool := newCompleteTaskTool("/tmp/secrets")
	if tool.Name() != completeTaskToolName {
		t.Errorf("Name() = %q, want %q", tool.Name(), completeTaskToolName)
	}
}

func TestCompleteTaskTool_MissingTaskID(t *testing.T) {
	t.Parallel()
	tool := newCompleteTaskTool("/tmp/secrets")
	_, err := tool.Execute(context.Background(), "session:1", "", map[string]any{"task_id": ""})
	if err == nil {
		t.Fatal("expected error for missing task_id, got nil")
	}
	if !strings.Contains(err.Error(), "task_id is required") {
		t.Errorf("error %q should contain 'task_id is required'", err.Error())
	}
}

func TestUpdateTaskTool_Name(t *testing.T) {
	t.Parallel()
	tool := newUpdateTaskTool("/tmp/secrets")
	if tool.Name() != updateTaskToolName {
		t.Errorf("Name() = %q, want %q", tool.Name(), updateTaskToolName)
	}
}

func TestUpdateTaskTool_MissingTaskID(t *testing.T) {
	t.Parallel()
	tool := newUpdateTaskTool("/tmp/secrets")
	_, err := tool.Execute(context.Background(), "session:1", "", map[string]any{
		"task_id": "",
		"title":   "something",
	})
	if err == nil {
		t.Fatal("expected error for missing task_id, got nil")
	}
	if !strings.Contains(err.Error(), "task_id is required") {
		t.Errorf("error %q should contain 'task_id is required'", err.Error())
	}
}

func TestCompleteTaskTool_Declaration(t *testing.T) {
	t.Parallel()
	tool := newCompleteTaskTool("/tmp/secrets")
	decl := tool.Declaration()

	props, _ := decl.Parameters["properties"].(map[string]any)
	if _, ok := props["task_id"]; !ok {
		t.Error("Declaration missing task_id parameter")
	}
	found := false
	reqs, _ := decl.Parameters["required"].([]string)
	for _, r := range reqs {
		if r == "task_id" {
			found = true
		}
	}
	if !found {
		t.Error("task_id must be in Required")
	}
}

func TestUpdateTaskTool_Declaration(t *testing.T) {
	t.Parallel()
	tool := newUpdateTaskTool("/tmp/secrets")
	decl := tool.Declaration()

	props, _ := decl.Parameters["properties"].(map[string]any)
	for _, p := range []string{"task_id", "title", "notes", "due", "tasklist_id"} {
		if _, ok := props[p]; !ok {
			t.Errorf("Declaration missing parameter %q", p)
		}
	}
	reqs, _ := decl.Parameters["required"].([]string)
	if len(reqs) != 1 || reqs[0] != "task_id" {
		t.Errorf("Required should be [task_id], got %v", reqs)
	}
}
