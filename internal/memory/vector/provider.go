package vector

import (
	"context"
	"fmt"
	"strings"

	"google.golang.org/genai"
)

// EmbeddingProvider defines the interface for generating vector embeddings from text.
type EmbeddingProvider interface {
	Embed(ctx context.Context, text string) ([]float32, error)
}

// GeminiProvider implements EmbeddingProvider using the Gemini text-embedding-004 model.
type GeminiProvider struct {
	client *genai.Client
	model  string
}

// NewGeminiProvider creates a new EmbeddingProvider with the Gemini client.
func NewGeminiProvider(client *genai.Client) *GeminiProvider {
	return &GeminiProvider{
		client: client,
		model:  "text-embedding-004",
	}
}

// Embed generates an embedding for the given text.
// This signature matches chromem.EmbeddingFunc.
func (p *GeminiProvider) Embed(ctx context.Context, text string) ([]float32, error) {
	if strings.TrimSpace(text) == "" {
		return nil, fmt.Errorf("gemini embed: empty text")
	}

	contents := []*genai.Content{{Parts: []*genai.Part{{Text: text}}}}
	resp, err := p.client.Models.EmbedContent(ctx, p.model, contents, nil)
	if err != nil {
		return nil, fmt.Errorf("gemini embed content: %w", err)
	}

	if len(resp.Embeddings) == 0 || len(resp.Embeddings[0].Values) == 0 {
		return nil, fmt.Errorf("gemini embed returned no embeddings")
	}

	return resp.Embeddings[0].Values, nil
}
