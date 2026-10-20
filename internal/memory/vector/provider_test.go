//nolint:testpackage // requires unexported vector internals for testing
package vector

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"go.opentelemetry.io/otel/trace"
)

// errReader fails on Read, to exercise the response-body read-error branch.
type errReader struct{}

func (errReader) Read([]byte) (int, error) { return 0, fmt.Errorf("simulated read failure") }

func TestNewGeminiProvider_StoresModel(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name  string
		model string
	}{
		{
			name:  "standard embedding model",
			model: "text-embedding-004",
		},
		{
			name:  "custom embedding model",
			model: "my-custom-embedding-model",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			p := NewGeminiProvider("test-api-key", tc.model)
			if p.model != tc.model {
				t.Errorf("NewGeminiProvider model = %q, want %q", p.model, tc.model)
			}
		})
	}
}

func TestGeminiProvider_marshalRequest(t *testing.T) {
	t.Parallel()
	p := NewGeminiProvider("k", "gemini-embedding-2")
	body, err := p.marshalRequest(`hi "world"`)
	if err != nil {
		t.Fatalf("marshalRequest: %v", err)
	}
	var got embedContentRequest
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("unmarshal round-trip: %v (body=%s)", err, body)
	}
	if len(got.Content.Parts) != 1 || got.Content.Parts[0].Text != `hi "world"` {
		t.Errorf("unexpected request shape: %s", body)
	}
	if got.OutputDimensionality != EmbeddingDimensions {
		t.Errorf("output dimensionality = %d, want %d", got.OutputDimensionality, EmbeddingDimensions)
	}
	if !strings.Contains(string(body), `"parts"`) || !strings.Contains(string(body), `"text"`) {
		t.Errorf("missing expected JSON keys: %s", body)
	}
}

func TestCacheFilename(t *testing.T) {
	t.Parallel()
	defaultName := CacheFilename("gemini-embedding-2")
	if defaultName != CacheFilename("gemini-embedding-2") {
		t.Error("cache filename must be deterministic")
	}
	if !strings.Contains(defaultName, "gemini-embedding-2-768-") || strings.ContainsAny(defaultName, `\\/:*?\"<>|`) {
		t.Errorf("cache filename %q is not model/dimension-specific and filesystem-safe", defaultName)
	}
	if defaultName == CacheFilename("custom/model") || CacheFilename("custom/model") == CacheFilename("custom-model") {
		t.Error("distinct models must have distinct cache identities")
	}
}

func TestGeminiProvider_buildURL(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name    string
		model   string
		wantSeg string
	}{
		{"bare model gets models/ prefix", "text-embedding-004", "models/text-embedding-004:embedContent"},
		{"already prefixed not doubled", "models/text-embedding-004", "models/text-embedding-004:embedContent"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			p := NewGeminiProvider("secret-key", tc.model)
			url := p.buildURL()
			if !strings.Contains(url, tc.wantSeg) {
				t.Errorf("url %q missing segment %q", url, tc.wantSeg)
			}
			if strings.Contains(url, "models/models/") {
				t.Errorf("double models/ prefix in %q", url)
			}
			if !strings.Contains(url, "key=secret-key") {
				t.Errorf("url %q missing api key", url)
			}
			if !strings.HasPrefix(url, geminiEmbedBaseURL) {
				t.Errorf("url %q missing base URL", url)
			}
		})
	}
}

func noopSpan() trace.Span {
	return trace.SpanFromContext(context.Background())
}

func makeResp(code int, body string) *http.Response {
	return &http.Response{StatusCode: code, Body: io.NopCloser(strings.NewReader(body))}
}

func assertErrContains(t *testing.T, err error, want string) {
	t.Helper()
	if err == nil || !strings.Contains(err.Error(), want) {
		t.Errorf("expected error containing %q, got %v", want, err)
	}
}

func TestGeminiProvider_parseResponse(t *testing.T) {
	t.Parallel()
	p := NewGeminiProvider("k", "m")

	t.Run("success", func(t *testing.T) {
		t.Parallel()
		vals, err := p.parseResponse(makeResp(http.StatusOK, `{"embedding":{"values":[0.1,0.2,0.3]}}`), noopSpan())
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if len(vals) != 3 || vals[0] != 0.1 {
			t.Errorf("unexpected values: %v", vals)
		}
	})

	t.Run("non-200 includes status and body", func(t *testing.T) {
		t.Parallel()
		_, err := p.parseResponse(makeResp(http.StatusForbidden, "forbidden detail"), noopSpan())
		assertErrContains(t, err, "403")
		assertErrContains(t, err, "forbidden detail")
	})

	t.Run("invalid json", func(t *testing.T) {
		t.Parallel()
		_, err := p.parseResponse(makeResp(http.StatusOK, "not json"), noopSpan())
		assertErrContains(t, err, "parse response")
	})

	t.Run("empty values", func(t *testing.T) {
		t.Parallel()
		_, err := p.parseResponse(makeResp(http.StatusOK, `{"embedding":{"values":[]}}`), noopSpan())
		assertErrContains(t, err, "no embeddings")
	})

	t.Run("body read error", func(t *testing.T) {
		t.Parallel()
		resp := &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(errReader{})}
		_, err := p.parseResponse(resp, noopSpan())
		assertErrContains(t, err, "read response")
	})
}

func TestGeminiProvider_Embed(t *testing.T) {
	t.Parallel()

	t.Run("success via injected server", func(t *testing.T) {
		t.Parallel()
		var gotPath string
		var gotBody []byte
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			gotPath = r.URL.Path
			gotBody, _ = io.ReadAll(r.Body)
			_, _ = w.Write([]byte(`{"embedding":{"values":[1,2,3]}}`))
		}))
		defer srv.Close()

		p := NewGeminiProvider("k", "gemini-embedding-2")
		p.baseURL = srv.URL
		p.httpClient = srv.Client()

		vals, err := p.Embed(context.Background(), "hello")
		if err != nil {
			t.Fatalf("Embed: %v", err)
		}
		if len(vals) != 3 {
			t.Errorf("unexpected values: %v", vals)
		}
		if !strings.Contains(gotPath, "models/gemini-embedding-2:embedContent") {
			t.Errorf("unexpected request path %q", gotPath)
		}
		if !strings.Contains(string(gotBody), `"hello"`) {
			t.Errorf("request body missing text: %s", gotBody)
		}
		if !strings.Contains(string(gotBody), `"output_dimensionality":768`) {
			t.Errorf("request body missing fixed output dimensionality: %s", gotBody)
		}
	})

	t.Run("empty text makes no request", func(t *testing.T) {
		t.Parallel()
		hit := false
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			hit = true
			w.WriteHeader(http.StatusOK)
		}))
		defer srv.Close()

		p := NewGeminiProvider("k", "m")
		p.baseURL = srv.URL
		p.httpClient = srv.Client()

		if _, err := p.Embed(context.Background(), "   "); err == nil {
			t.Error("expected an error for empty/whitespace text")
		}
		if hit {
			t.Error("expected NO HTTP request for empty text")
		}
	})
}

func TestGeminiProvider_Embed_Errors(t *testing.T) {
	t.Parallel()

	t.Run("non-200 returns error", func(t *testing.T) {
		t.Parallel()
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte("boom"))
		}))
		defer srv.Close()

		p := NewGeminiProvider("k", "m")
		p.baseURL = srv.URL
		p.httpClient = srv.Client()

		_, err := p.Embed(context.Background(), "hello")
		assertErrContains(t, err, "500")
	})

	t.Run("transport error", func(t *testing.T) {
		t.Parallel()
		srv := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, _ *http.Request) {}))
		url := srv.URL
		client := srv.Client()
		srv.Close() // connections now fail

		p := NewGeminiProvider("k", "m")
		p.baseURL = url
		p.httpClient = client

		_, err := p.Embed(context.Background(), "hello")
		assertErrContains(t, err, "http")
	})

	t.Run("invalid base URL returns request-creation error", func(t *testing.T) {
		t.Parallel()
		p := NewGeminiProvider("k", "m")
		p.baseURL = "http://\x7f-invalid" // control char makes URL parsing fail in NewRequest
		_, err := p.Embed(context.Background(), "hello")
		assertErrContains(t, err, "create request")
	})
}

//nolint:gocognit,cyclop,funlen // table of stall scenarios with local helpers
func TestGeminiProvider_Embed_RequestBounds(t *testing.T) {
	t.Parallel()
	const guard = 30 * time.Second

	newServer := func(t *testing.T, mode string) (*httptest.Server, <-chan struct{}) {
		t.Helper()
		arrived := make(chan struct{}, 1)
		ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			_, _ = io.Copy(io.Discard, r.Body) // lets the server notice a client disconnect
			select {
			case arrived <- struct{}{}:
			default:
			}
			if mode == "body" {
				w.WriteHeader(http.StatusOK)
				_, _ = w.Write([]byte(`{"embedding":`))
				if f, ok := w.(http.Flusher); ok {
					f.Flush()
				}
			}
			<-r.Context().Done()
		}))
		t.Cleanup(ts.Close)
		return ts, arrived
	}
	run := func(t *testing.T, fn func() error) error {
		t.Helper()
		done := make(chan error, 1)
		go func() { done <- fn() }()
		select {
		case err := <-done:
			return err
		case <-time.After(guard):
			t.Fatal("request did not terminate: no finite deadline applied")
			return nil
		}
	}
	build := func(url string, d time.Duration) *GeminiProvider {
		p := NewGeminiProvider("k", "m")
		p.baseURL = url
		p.httpClient = http.DefaultClient
		p.requestTimeout = d
		return p
	}

	for _, mode := range []string{"header", "body"} {
		t.Run(mode+" stall hits operational timeout", func(t *testing.T) {
			t.Parallel()
			ts, _ := newServer(t, mode)
			p := build(ts.URL, 50*time.Millisecond)
			err := run(t, func() error { _, e := p.Embed(context.Background(), "hello"); return e })
			if !errors.Is(err, context.DeadlineExceeded) {
				t.Fatalf("got %v, want context.DeadlineExceeded", err)
			}
		})
		t.Run(mode+" stall honors earlier parent deadline", func(t *testing.T) {
			t.Parallel()
			ts, _ := newServer(t, mode)
			p := build(ts.URL, time.Hour)
			ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
			defer cancel()
			err := run(t, func() error { _, e := p.Embed(ctx, "hello"); return e })
			if !errors.Is(err, context.DeadlineExceeded) {
				t.Fatalf("got %v, want context.DeadlineExceeded", err)
			}
		})
		t.Run(mode+" stall honors parent cancellation", func(t *testing.T) {
			t.Parallel()
			ts, arrived := newServer(t, mode)
			p := build(ts.URL, time.Hour)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			go func() {
				<-arrived
				cancel()
			}()
			err := run(t, func() error { _, e := p.Embed(ctx, "hello"); return e })
			if !errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
				t.Fatalf("got %v, want context.Canceled only", err)
			}
		})
	}
}

func TestGeminiProvider_DefaultRequestTimeout(t *testing.T) {
	t.Parallel()
	if defaultEmbedRequestTimeout <= 0 || NewGeminiProvider("k", "m").requestTimeout != 0 {
		t.Fatal("embed default must be finite and applied when the field is zero")
	}
}
