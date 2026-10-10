//nolint:testpackage // intentionally uses unexported helpers from main package
package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/integrations/google"
	"github.com/allthingscode/gobot/internal/observability"
	"github.com/allthingscode/gobot/internal/provider"
)

func TestWebSearchTool(t *testing.T) {
	t.Parallel()
	// Mock Google Search API
	mux := http.NewServeMux()
	mux.HandleFunc("/", mockGoogleSearchHandler)

	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)

	type testCase struct {
		name    string
		apiKey  string
		cx      string
		args    map[string]any
		wantErr bool
		errSub  string
		wantSub string
	}
	tests := []testCase{
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
			tool := newWebSearchTool(tt.apiKey, tt.cx, nil)
			tool.baseURL = server.URL // Override for testing

			res, err := tool.Execute(context.Background(), "test-session", "", tt.args)
			validateWebSearchResult(t, tt, res, err)
		})
	}
}

func mockGoogleSearchHandler(w http.ResponseWriter, r *http.Request) {
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
}

func validateWebSearchResult(t *testing.T, tt struct {
	name    string
	apiKey  string
	cx      string
	args    map[string]any
	wantErr bool
	errSub  string
	wantSub string
}, res string, err error) {
	t.Helper()
	if (err != nil) != tt.wantErr {
		t.Fatalf("Execute() error = %v, wantErr %v", err, tt.wantErr)
	}
	if tt.wantErr && tt.errSub != "" && !strings.Contains(err.Error(), tt.errSub) {
		t.Errorf("Execute() error = %v, want error containing %q", err, tt.errSub)
	}
	if !tt.wantErr && tt.wantSub != "" && !strings.Contains(res, tt.wantSub) {
		t.Errorf("Execute() = %q, want it to contain %q", res, tt.wantSub)
	}
}

func TestCompleteTaskTool_Name(t *testing.T) {
	t.Parallel()
	tool := newCompleteTaskTool("/tmp/secrets", nil)
	if tool.Name() != completeTaskToolName {
		t.Errorf("Name() = %q, want %q", tool.Name(), completeTaskToolName)
	}
}

func TestCompleteTaskTool_MissingTaskID(t *testing.T) {
	t.Parallel()
	tool := newCompleteTaskTool("/tmp/secrets", nil)
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
	tool := newUpdateTaskTool("/tmp/secrets", nil)
	if tool.Name() != updateTaskToolName {
		t.Errorf("Name() = %q, want %q", tool.Name(), updateTaskToolName)
	}
}

func TestUpdateTaskTool_MissingTaskID(t *testing.T) {
	t.Parallel()
	tool := newUpdateTaskTool("/tmp/secrets", nil)
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
	tool := newCompleteTaskTool("/tmp/secrets", nil)
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
	tool := newUpdateTaskTool("/tmp/secrets", nil)
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

type googleSearchTransport func(*http.Request) (*http.Response, error)

func (f googleSearchTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

const googleSearchSyntheticKey = "synthetic/key+ secret"

func failingSearchTool(traced, redirect bool, cause error) *WebSearchTool {
	var tracer *observability.DispatchTracer
	if traced {
		tracer = observability.NewDispatchTracer(nil)
	}
	tool := newWebSearchTool(googleSearchSyntheticKey, "cx", tracer)
	tool.baseURL = "https://search.invalid/search"
	tool.httpClient = &http.Client{
		Transport: googleSearchTransport(func(r *http.Request) (*http.Response, error) {
			if redirect {
				return &http.Response{StatusCode: 302, Header: http.Header{"Location": {r.URL.String() + "&redirect=1"}}, Body: http.NoBody}, nil
			}
			return nil, fmt.Errorf("request %s: %w", r.URL, cause)
		}),
		CheckRedirect: func(r *http.Request, _ []*http.Request) error { return fmt.Errorf("redirect %s: %w", r.URL, cause) },
	}
	return tool
}

func assertSafeGoogleSearch(t *testing.T, text string) {
	t.Helper()
	for _, required := range []string{"google_search", "search request", "transport or redirect failure"} {
		if !strings.Contains(text, required) {
			t.Fatalf("missing %q in %q", required, text)
		}
	}
	for _, secret := range []string{googleSearchSyntheticKey, url.QueryEscape(googleSearchSyntheticKey), "https://search.invalid", "key="} {
		if strings.Contains(text, secret) {
			t.Fatalf("disclosed %q in %q", secret, text)
		}
	}
}

//nolint:gocognit // Matrix checks both tracing paths against all error classifications.
func TestWebSearchSafeErrors(t *testing.T) {
	t.Parallel()
	sentinel := errors.New("offline sentinel")
	for _, traced := range []bool{false, true} {
		for _, cause := range []error{sentinel, context.Canceled, context.DeadlineExceeded, &net.DNSError{IsTimeout: true}} {
			t.Run(fmt.Sprintf("traced=%v/%v", traced, cause), func(t *testing.T) {
				t.Parallel()
				tool := failingSearchTool(traced, false, cause)
				_, err := tool.Execute(context.Background(), "session", "user", map[string]any{"query": "q"})
				if err == nil || !errors.Is(err, cause) {
					t.Fatalf("lost cause: %v", err)
				}
				assertSafeGoogleSearch(t, err.Error())
				var timeout net.Error
				if errors.As(cause, &timeout) {
					var got net.Error
					if !errors.As(err, &got) || !got.Timeout() {
						t.Fatal("lost timeout")
					}
				}
			})
		}
	}
}

type googleSearchProvider struct{ requests []provider.ChatRequest }

func (*googleSearchProvider) Name() string                 { return "offline-search" }
func (*googleSearchProvider) Models() []provider.ModelInfo { return nil }
func (p *googleSearchProvider) Chat(_ context.Context, req provider.ChatRequest) (*provider.ChatResponse, error) {
	p.requests = append(p.requests, req)
	if len(p.requests) == 1 {
		return &provider.ChatResponse{Message: agentctx.StrategicMessage{Role: agentctx.RoleAssistant, ToolCalls: []agentctx.ToolCall{{ID: "search-1", Name: webSearchToolName, Args: map[string]any{"query": "q"}}}}}, nil
	}
	text := "Search is unavailable."
	return &provider.ChatResponse{Message: agentctx.StrategicMessage{Role: agentctx.RoleAssistant, Content: &agentctx.MessageContent{Str: &text}}}, nil
}

func assertGoogleSearchToolMessage(t *testing.T, messages []agentctx.StrategicMessage) {
	t.Helper()
	found := false
	for _, msg := range messages {
		if msg.Role == agentctx.RoleTool {
			found = true
			text := ExtractText(msg)
			if !strings.Contains(text, "TOOL_ERROR [google_search]") {
				t.Fatalf("missing actual TOOL_ERROR: %q", text)
			}
			assertSafeGoogleSearch(t, text)
		}
	}
	if !found {
		t.Fatal("missing tool message")
	}
	data, err := json.Marshal(messages)
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{googleSearchSyntheticKey, url.QueryEscape(googleSearchSyntheticKey), "https://search.invalid", "key="} {
		if strings.Contains(string(data), secret) {
			t.Fatalf("history disclosed %q", secret)
		}
	}
}

//nolint:gocognit // End-to-end matrix includes real runner, model and reopened SQLite evidence.
func TestGoogleSearchPipelineBoundary(t *testing.T) {
	t.Parallel()
	for _, redirect := range []bool{false, true} {
		for _, traced := range []bool{false, true} {
			t.Run(fmt.Sprintf("redirect=%v/traced=%v", redirect, traced), func(t *testing.T) {
				t.Parallel()
				dir := t.TempDir()
				store, err := agentctx.GetCheckpointManager(dir)
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { agentctx.EvictCheckpointManagerForTest(dir) })
				prov := &googleSearchProvider{}
				runner := NewAgentRunner(prov, "offline", "", &config.Config{})
				runner.SetTools([]Tool{failingSearchTool(traced, redirect, errors.New("offline"))})
				mgr := agent.NewSessionManager(runner, store, "offline")
				_, err = mgr.Dispatch(context.Background(), "search-session", "user", "search")
				if err != nil {
					t.Fatal(err)
				}
				if len(prov.requests) != 2 {
					t.Fatalf("model calls=%d, want 2", len(prov.requests))
				}
				assertGoogleSearchToolMessage(t, prov.requests[1].Messages)
				// Close and reopen the real SQLite store to prove durability.
				agentctx.EvictCheckpointManagerForTest(dir)
				reopened, err := agentctx.GetCheckpointManager(dir)
				if err != nil {
					t.Fatal(err)
				}
				snap, err := reopened.LoadLatest(context.Background(), "search-session")
				if err != nil || snap == nil {
					t.Fatalf("missing stored snapshot: %v", err)
				}
				assertGoogleSearchToolMessage(t, snap.Messages)
			})
		}
	}
}

func TestGoogleSearchRunnerCancellation(t *testing.T) {
	t.Parallel()
	for _, cause := range []error{context.Canceled, context.DeadlineExceeded} {
		t.Run(cause.Error(), func(t *testing.T) {
			t.Parallel()
			prov := &googleSearchProvider{}
			runner := NewAgentRunner(prov, "offline", "", &config.Config{})
			runner.SetTools([]Tool{failingSearchTool(false, false, cause)})
			mgr := agent.NewSessionManager(runner, nil, "offline")
			result, err := mgr.Dispatch(context.Background(), "search-session", "user", "search")
			if !errors.Is(err, cause) || result != "" || len(prov.requests) != 1 {
				t.Fatalf("cancellation became tool result: result=%q err=%v calls=%d", result, err, len(prov.requests))
			}
		})
	}
}
