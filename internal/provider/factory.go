package provider

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/allthingscode/gobot/internal/config"
	"google.golang.org/genai"
)

// Factory initializes all configured providers and registers them.
type Factory struct {
	GeminiAPIKey      string
	AnthropicAPIKey   string
	OpenAIAPIKey      string
	OpenAIBaseURL     string
	OpenRouterAPIKey  string
	OpenRouterBaseURL string
}

// InitAll initializes and registers all providers for which an API key is present.
//nolint:gocognit,cyclop // Provider registration is inherently linear
func (f *Factory) InitAll(ctx context.Context, cfg *config.Config) error {
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

	// OpenRouter
	if f.OpenRouterAPIKey != "" || f.OpenRouterBaseURL != "" {
		if err := Register(NewOpenRouterProvider(f.OpenRouterAPIKey, f.OpenRouterBaseURL)); err != nil {
			return fmt.Errorf("register openrouter: %w", err)
		}
	}

	// Cost-based Routing (F-116)
	if cfg != nil && cfg.Strategic.Routing.Enabled {
		if err := f.setupRouting(cfg); err != nil {
			slog.Warn("factory: routing setup failed, continuing with direct providers", "err", err)
		}
	}

	return nil
}

func (f *Factory) setupRouting(cfg *config.Config) error {
	rCfg := cfg.Strategic.Routing

	// Default provider is the 'executor' for routing.
	execProvName := cfg.DefaultProvider()
	execProv, err := Get(execProvName)
	if err != nil {
		return fmt.Errorf("executor provider %q: %w", execProvName, err)
	}

	mgrProvName := rCfg.ManagerProvider
	if mgrProvName == "" {
		mgrProvName = execProvName
	}
	mgrProv, err := Get(mgrProvName)
	if err != nil {
		return fmt.Errorf("manager provider %q: %w", mgrProvName, err)
	}

	routingProv := NewRoutingProvider(execProv, mgrProv, rCfg)
	slog.Info("factory: cost routing initialized", "manager", rCfg.ManagerModel)

	// Register the routing provider centrally. App layer can now retrieve
	// it via provider.Get("routing") if enabled.
	return Register(routingProv)
}
