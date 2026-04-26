package vector

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"
)

// EmbeddingProvider defines the interface for generating vector embeddings from text.
type EmbeddingProvider interface {
	Embed(ctx context.Context, text string) ([]float32, error)
}

// GeminiProvider implements EmbeddingProvider via the Gemini REST embedContent API.
// It bypasses the genai SDK's batchEmbedContents which does not support text-embedding-004.
type GeminiProvider struct {
	apiKey string
	model  string
}

// NewGeminiProvider creates a new EmbeddingProvider using the Gemini REST API directly.
func NewGeminiProvider(apiKey, model string) *GeminiProvider {
	return &GeminiProvider{apiKey: apiKey, model: model}
}

type embedContentRequest struct {
	Content struct {
		Parts []struct {
			Text string `json:"text"`
		} `json:"parts"`
	} `json:"content"`
}

type embedContentResponse struct {
	Embedding struct {
		Values []float32 `json:"values"`
	} `json:"embedding"`
}

// Embed generates an embedding for the given text via the Gemini embedContent REST API.
func (p *GeminiProvider) Embed(ctx context.Context, text string) ([]float32, error) {
	ctx, span := otel.Tracer("gobot-strategic").Start(ctx, "gemini.embed")
	defer span.End()

	if strings.TrimSpace(text) == "" {
		err := fmt.Errorf("gemini embed: empty text")
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
		return nil, err
	}

	body, err := p.marshalRequest(text)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
		return nil, err
	}

	url := p.buildURL()
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		err = fmt.Errorf("gemini embed: create request: %w", err)
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
		return nil, err
	}
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		err = fmt.Errorf("gemini embed: http: %w", err)
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }()

	return p.parseResponse(resp, span)
}

func (p *GeminiProvider) marshalRequest(text string) ([]byte, error) {
	var req embedContentRequest
	req.Content.Parts = []struct {
		Text string `json:"text"`
	}{{Text: text}}

	body, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("gemini embed: marshal: %w", err)
	}
	return body, nil
}

func (p *GeminiProvider) buildURL() string {
	model := p.model
	if !strings.HasPrefix(model, "models/") {
		model = "models/" + model
	}
	return fmt.Sprintf("https://generativelanguage.googleapis.com/v1beta/%s:embedContent?key=%s", model, p.apiKey)
}

func (p *GeminiProvider) parseResponse(resp *http.Response, span trace.Span) ([]float32, error) {
	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		err = fmt.Errorf("gemini embed: read response: %w", err)
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		err = fmt.Errorf("gemini embed content: HTTP %d: %s", resp.StatusCode, respBody)
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
		return nil, err
	}

	var embedResp embedContentResponse
	if err := json.Unmarshal(respBody, &embedResp); err != nil {
		err = fmt.Errorf("gemini embed: parse response: %w", err)
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
		return nil, err
	}
	if len(embedResp.Embedding.Values) == 0 {
		err = fmt.Errorf("gemini embed returned no embeddings")
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
		return nil, err
	}

	return embedResp.Embedding.Values, nil
}
