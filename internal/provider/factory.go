package provider

import (
	"context"
	"fmt"

	"google.golang.org/genai"
)

// Factory initializes all configured providers and registers them.
type Factory struct {
	GeminiAPIKey    string
	AnthropicAPIKey string
	OpenAIAPIKey    string
	OpenAIBaseURL   string
}

// InitAll initializes and registers all providers for which an API key is present.
func (f *Factory) InitAll(ctx context.Context) error {
	// Gemini
	if f.GeminiAPIKey != "" {
		client, err := genai.NewClient(ctx, &genai.ClientConfig{
			APIKey:  f.GeminiAPIKey,
			Backend: genai.BackendGeminiAPI,
		})
		if err != nil {
			return fmt.Errorf("gemini client: %w", err)
		}
		Register(NewGeminiProvider(client))
	}

	// Anthropic
	if f.AnthropicAPIKey != "" {
		Register(NewAnthropicProvider(f.AnthropicAPIKey))
	}

	// OpenAI / Compatible
	if f.OpenAIAPIKey != "" || f.OpenAIBaseURL != "" {
		Register(NewOpenAIProvider(f.OpenAIAPIKey, f.OpenAIBaseURL))
	}

	return nil
}
