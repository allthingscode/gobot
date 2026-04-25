package vector

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
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
	if strings.TrimSpace(text) == "" {
		return nil, fmt.Errorf("gemini embed: empty text")
	}

	var req embedContentRequest
	req.Content.Parts = []struct {
		Text string `json:"text"`
	}{{Text: text}}

	body, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("gemini embed: marshal: %w", err)
	}

	model := p.model
	if !strings.HasPrefix(model, "models/") {
		model = "models/" + model
	}
	url := fmt.Sprintf("https://generativelanguage.googleapis.com/v1beta/%s:embedContent?key=%s", model, p.apiKey)

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("gemini embed: create request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("gemini embed: http: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("gemini embed: read response: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("gemini embed content: HTTP %d: %s", resp.StatusCode, respBody)
	}

	var embedResp embedContentResponse
	if err := json.Unmarshal(respBody, &embedResp); err != nil {
		return nil, fmt.Errorf("gemini embed: parse response: %w", err)
	}
	if len(embedResp.Embedding.Values) == 0 {
		return nil, fmt.Errorf("gemini embed returned no embeddings")
	}

	return embedResp.Embedding.Values, nil
}
