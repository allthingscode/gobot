//nolint:testpackage // requires unexported openai provider internals for testing
package provider

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	agentctx "github.com/allthingscode/gobot/internal/context"
)

func TestOpenAIProvider_Name(t *testing.T) {
	t.Parallel()
	p := NewOpenAIProvider("test-key", "")
	if p.Name() != "openai" { //nolint:goconst // test fixture
		t.Errorf("got %q, want %q", p.Name(), "openai")
	}
}

func TestOpenAIProvider_Models(t *testing.T) {
	t.Parallel()
	p := NewOpenAIProvider("test-key", "")
	models := p.Models()
	if len(models) == 0 {
		t.Fatal("expected models")
	}
	found := false
	for _, m := range models {
		if m.ID == "gpt-6.1-sol" {
			found = true
			if !m.SupportsToolUse {
				t.Error("expected gpt-6.1-sol to support tool use")
			}
			break
		}
	}
	if !found {
		t.Error("expected gpt-6.1-sol in models")
	}
}

//nolint:cyclop,funlen // test complexity justified by multi-step verification
func TestOpenAIProvider_Chat_Success(t *testing.T) {
	t.Parallel()
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer test-key" {
			t.Errorf("missing or incorrect auth header: %s", r.Header.Get("Authorization"))
		}

		var req openAIRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("failed to decode request: %v", err)
		}

		if len(req.Messages) != 2 {
			t.Errorf("got %d messages, want 2 (system + user)", len(req.Messages))
		}
		if req.Messages[0].Role != "system" {
			t.Errorf("got first role %q, want 'system'", req.Messages[0].Role)
		}

		resp := openAIResponse{}
		resp.Choices = append(resp.Choices, struct {
			Message struct {
				Role      string           `json:"role"`
				Content   string           `json:"content"`
				ToolCalls []openAIToolCall `json:"tool_calls"`
			} `json:"message"`
		}{
			Message: struct {
				Role      string           `json:"role"`
				Content   string           `json:"content"`
				ToolCalls []openAIToolCall `json:"tool_calls"`
			}{
				Role:    "assistant",
				Content: "hello from openai",
				ToolCalls: []openAIToolCall{
					{
						ID:   "call_123",
						Type: "function",
						Function: struct {
							Name      string `json:"name"`
							Arguments string `json:"arguments"`
						}{
							Name:      "my_tool",
							Arguments: `{"arg1":"val1"}`,
						},
					},
				},
			},
		})
		resp.Usage.PromptTokens = 5
		resp.Usage.CompletionTokens = 15
		resp.Usage.TotalTokens = 20

		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	}))
	defer ts.Close()

	p := NewOpenAIProvider("test-key", ts.URL)
	str := "hello" //nolint:goconst // test fixture
	req := ChatRequest{
		Model:             "gpt-6.1-sol",
		SystemInstruction: "system prompt",
		Messages: []agentctx.StrategicMessage{
			{
				Role:    agentctx.RoleUser,
				Content: &agentctx.MessageContent{Str: &str},
			},
		},
		MaxTokens: 100,
	}

	resp, err := p.Chat(context.Background(), req)
	if err != nil {
		t.Fatalf("Chat failed: %v", err)
	}

	if resp.Usage.PromptTokens != 5 {
		t.Errorf("got %d prompt tokens, want 5", resp.Usage.PromptTokens)
	}
	if resp.Usage.TotalTokens != 20 {
		t.Errorf("got %d total tokens, want 20", resp.Usage.TotalTokens)
	}
	if resp.Message.Content == nil || *resp.Message.Content.Str != "hello from openai" {
		t.Errorf("unexpected content: %v", resp.Message.Content)
	}
	if len(resp.Message.ToolCalls) != 1 {
		t.Fatalf("got %d tool calls, want 1", len(resp.Message.ToolCalls))
	}
	if resp.Message.ToolCalls[0].Name != "my_tool" { //nolint:goconst // test fixture
		t.Errorf("got tool name %q, want 'my_tool'", resp.Message.ToolCalls[0].Name)
	}
}

func TestOpenAIProvider_Chat_Error(t *testing.T) {
	t.Parallel()
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":{"type":"invalid_request_error","message":"bad request"}}`))
	}))
	defer ts.Close()

	p := NewOpenAIProvider("test-key", ts.URL)
	req := ChatRequest{
		Model: "gpt-6.1-sol",
	}

	_, err := p.Chat(context.Background(), req)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !strings.Contains(err.Error(), "invalid_request_error") {
		t.Errorf("expected invalid_request_error, got: %v", err)
	}
}

const testGuard = 30 * time.Second

// newStallServer returns a server that accepts a request, signals arrived and
// then stalls until the client gives up. In "body" mode it first sends response
// headers and a partial body.
func newStallServer(t *testing.T, mode string) (srv *httptest.Server, arrived <-chan struct{}) {
	t.Helper()
	signal := make(chan struct{}, 1)
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body) // lets the server notice a client disconnect
		select {
		case signal <- struct{}{}:
		default:
		}
		if mode == "body" {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"choices":[`))
			if f, ok := w.(http.Flusher); ok {
				f.Flush()
			}
		}
		<-r.Context().Done()
	}))
	t.Cleanup(ts.Close)
	return ts, signal
}

func runGuarded(t *testing.T, fn func() error) error {
	t.Helper()
	done := make(chan error, 1)
	go func() { done <- fn() }()
	select {
	case err := <-done:
		return err
	case <-time.After(testGuard):
		t.Fatal("request did not terminate: no finite deadline applied")
		return nil
	}
}

// runStallMatrix exercises header and body stalls against the operational
// timeout, an earlier parent deadline and explicit parent cancellation.
// newCall builds a request func against url using the given operational timeout.
func runStallMatrix(t *testing.T, newCall func(url string, timeout time.Duration) func(context.Context) error) {
	t.Helper()
	for _, mode := range []string{"header", "body"} {
		t.Run(mode+" stall hits operational timeout", func(t *testing.T) {
			t.Parallel()
			ts, _ := newStallServer(t, mode)
			call := newCall(ts.URL, 50*time.Millisecond)
			err := runGuarded(t, func() error { return call(context.Background()) })
			if !errors.Is(err, context.DeadlineExceeded) {
				t.Fatalf("got %v, want context.DeadlineExceeded", err)
			}
		})
		t.Run(mode+" stall honors earlier parent deadline", func(t *testing.T) {
			t.Parallel()
			ts, _ := newStallServer(t, mode)
			call := newCall(ts.URL, time.Hour)
			ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
			defer cancel()
			err := runGuarded(t, func() error { return call(ctx) })
			if !errors.Is(err, context.DeadlineExceeded) {
				t.Fatalf("got %v, want context.DeadlineExceeded", err)
			}
		})
		t.Run(mode+" stall honors parent cancellation", func(t *testing.T) {
			t.Parallel()
			ts, arrived := newStallServer(t, mode)
			call := newCall(ts.URL, time.Hour)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			go func() {
				<-arrived
				cancel()
			}()
			err := runGuarded(t, func() error { return call(ctx) })
			if !errors.Is(err, context.Canceled) {
				t.Fatalf("got %v, want context.Canceled", err)
			}
			if errors.Is(err, context.DeadlineExceeded) {
				t.Fatalf("cancellation was replaced by a timeout error: %v", err)
			}
		})
	}
}

func chatRequestForTimeout() ChatRequest {
	str := "hello"
	return ChatRequest{
		Model:    "m",
		Messages: []agentctx.StrategicMessage{{Role: agentctx.RoleUser, Content: &agentctx.MessageContent{Str: &str}}},
	}
}

func TestOpenAIProvider_Chat_RequestBounds(t *testing.T) {
	t.Parallel()
	ctors := map[string]func(url string) *OpenAIProvider{
		"openai":     func(url string) *OpenAIProvider { return NewOpenAIProvider("k", url) },
		"openrouter": func(url string) *OpenAIProvider { return NewOpenRouterProvider("k", url) },
	}
	for name, ctor := range ctors {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			runStallMatrix(t, func(url string, d time.Duration) func(context.Context) error {
				p := ctor(url)
				p.requestTimeout = d
				return func(ctx context.Context) error {
					_, err := p.Chat(ctx, chatRequestForTimeout())
					return err
				}
			})
		})
	}
}

func TestOpenAIProvider_DefaultRequestTimeout(t *testing.T) {
	t.Parallel()
	if defaultChatRequestTimeout <= 0 {
		t.Fatalf("default chat timeout must be finite and positive, got %v", defaultChatRequestTimeout)
	}
	ctx, cancel := withRequestTimeout(context.Background(), 0, defaultChatRequestTimeout)
	defer cancel()
	dl, ok := ctx.Deadline()
	if !ok {
		t.Fatal("zero timeout must fall back to a finite default deadline")
	}
	if remaining := time.Until(dl); remaining > defaultChatRequestTimeout {
		t.Fatalf("deadline %v exceeds default %v", remaining, defaultChatRequestTimeout)
	}
}
