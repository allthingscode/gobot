package config

import (
	"fmt"
	"log/slog"
	"os"
	"strings"

	"github.com/allthingscode/gobot/internal/logattr"
	"github.com/allthingscode/gobot/internal/secrets"
)

// resolveSecret returns the first non-empty value from: configVal -> secrets store
// (looked up by storeKey) -> environment variable (envKey).
// store is passed in so callers can share a single SecretsStore instance.
func (c *Config) resolveSecret(store *secrets.SecretsStore, configVal, storeKey, envKey string) string {
	if configVal != "" {
		return configVal
	}
	val, err := store.Get(storeKey)
	if err != nil {
		slog.Warn("secrets store lookup failed, falling back to env", slog.String("key", storeKey), logattr.Err(err))
	}
	if val != "" {
		return val
	}
	return os.Getenv(envKey)
}

// GeminiAPIKey returns the Gemini API key. Priority order:
// 1. config.json field
// 2. DPAPI secrets store (gemini_api_key)
// 3. GEMINI_API_KEY environment variable (for CI / DPAPI-free environments).
func (c *Config) GeminiAPIKey() string {
	store := secrets.NewSecretsStore(c.StorageRoot())
	return c.resolveSecret(store, c.Providers.Gemini.APIKey, "gemini_api_key", "GEMINI_API_KEY")
}

// AnthropicAPIKey returns the Anthropic API key. Priority order:
// 1. config.json field
// 2. DPAPI secrets store (anthropic_api_key)
// 3. ANTHROPIC_API_KEY environment variable.
func (c *Config) AnthropicAPIKey() string {
	store := secrets.NewSecretsStore(c.StorageRoot())
	return c.resolveSecret(store, c.Providers.Anthropic.APIKey, "anthropic_api_key", "ANTHROPIC_API_KEY")
}

// OpenAIAPIKey returns the OpenAI API key. Priority order:
// 1. config.json field
// 2. DPAPI secrets store (openai_api_key)
// 3. OPENAI_API_KEY environment variable.
func (c *Config) OpenAIAPIKey() string {
	store := secrets.NewSecretsStore(c.StorageRoot())
	return c.resolveSecret(store, c.Providers.OpenAI.APIKey, "openai_api_key", "OPENAI_API_KEY")
}

// OpenAIBaseURL returns the OpenAI base URL. Priority order:
// 1. config.json field
// 2. DPAPI secrets store (openai_base_url)
// 3. OPENAI_BASE_URL environment variable.
func (c *Config) OpenAIBaseURL() string {
	store := secrets.NewSecretsStore(c.StorageRoot())
	return c.resolveSecret(store, c.Providers.OpenAI.BaseURL, "openai_base_url", "OPENAI_BASE_URL")
}

// OpenRouterAPIKey returns the OpenRouter API key. Priority order:
// 1. config.json field
// 2. DPAPI secrets store (openrouter_api_key)
// 3. OPENROUTER_API_KEY environment variable.
func (c *Config) OpenRouterAPIKey() string {
	store := secrets.NewSecretsStore(c.StorageRoot())
	return c.resolveSecret(store, c.Providers.OpenRouter.APIKey, "openrouter_api_key", "OPENROUTER_API_KEY")
}

// OpenRouterBaseURL returns the OpenRouter base URL. Priority order:
// 1. config.json field
// 2. DPAPI secrets store (openrouter_base_url)
// 3. OPENROUTER_BASE_URL environment variable.
func (c *Config) OpenRouterBaseURL() string {
	store := secrets.NewSecretsStore(c.StorageRoot())
	return c.resolveSecret(store, c.Providers.OpenRouter.BaseURL, "openrouter_base_url", "OPENROUTER_BASE_URL")
}

// GoogleAPIKey returns the Google Custom Search API key. Priority order:
// 1. config.json field
// 2. DPAPI secrets store (google_api_key)
// 3. GOOGLE_API_KEY environment variable.
func (c *Config) GoogleAPIKey() string {
	store := secrets.NewSecretsStore(c.StorageRoot())
	return c.resolveSecret(store, c.Providers.Google.APIKey, "google_api_key", "GOOGLE_API_KEY")
}

// GoogleCX returns the Google Custom Search Engine ID (CX). Priority order:
// 1. config.json field
// 2. DPAPI secrets store (google_cx)
// 3. GOOGLE_CX environment variable.
func (c *Config) GoogleCX() string {
	store := secrets.NewSecretsStore(c.StorageRoot())
	return c.resolveSecret(store, c.Providers.Google.CustomCX, "google_cx", "GOOGLE_CX")
}

// TelegramToken returns the Telegram bot token from config,
// falling back to the DPAPI secrets store or TELEGRAM_BOT_TOKEN environment variable.
func (c *Config) TelegramToken() string {
	store := secrets.NewSecretsStore(c.StorageRoot())
	return c.resolveSecret(store, c.Channels.Telegram.Token, "telegram_token", "TELEGRAM_BOT_TOKEN")
}

// TelegramAllowedFrom returns the list of allowed Telegram chat IDs.
func (c *Config) TelegramAllowedFrom() []string {
	return c.Channels.Telegram.AllowFrom
}

// MCPEnvFor returns the resolved environment variables for the named MCP server.
// For each env var, if the config value is empty, it is fetched from DPAPI under
// the key "mcp_env_{serverName}_{varName}" (both lowercased).
// Config values always take precedence over DPAPI values.
// Returns an empty map if the server is not found or has no env vars.
func (c *Config) MCPEnvFor(serverName string) map[string]string {
	return c.mcpEnvFor(serverName, secrets.NewSecretsStore(c.StorageRoot()))
}

// mcpEnvFor is the testable inner implementation of MCPEnvFor.
func (c *Config) mcpEnvFor(serverName string, store *secrets.SecretsStore) map[string]string {
	env := make(map[string]string)
	srv, ok := c.Tools.MCPServers[serverName]
	if !ok {
		return env
	}
	for varName, val := range srv.Env {
		if val != "" {
			env[varName] = val
			continue
		}
		// Value is empty — try DPAPI fallback.
		key := fmt.Sprintf("mcp_env_%s_%s",
			strings.ToLower(serverName),
			strings.ToLower(varName))
		v, err := store.Get(key)
		if err != nil {
			slog.Warn("secrets store lookup failed, falling back to env", slog.String("key", key), logattr.Err(err))
		}
		if v != "" {
			env[varName] = v
		}
	}
	return env
}
