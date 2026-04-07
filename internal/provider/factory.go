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
		if err := Register(NewGeminiProvider(client)); err != nil {
			return fmt.Errorf("register gemini: %w", err)
		}
	}

	// Anthropic
	if f.AnthropicAPIKey != "" {
		if err := Register(NewAnthropicProvider(f.AnthropicAPIKey, "")); err != nil {
			return fmt.Errorf("register anthropic: %w", err)
		}
	}

	// OpenAI / Compatible
	if f.OpenAIAPIKey != "" || f.OpenAIBaseURL != "" {
		if err := Register(NewOpenAIProvider(f.OpenAIAPIKey, f.OpenAIBaseURL)); err != nil {
			return fmt.Errorf("register openai: %w", err)
		}
	}

	return nil
}
