// Package config loads the nanobot config.json with BOM stripping and struct validation.
package config

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/allthingscode/gobot/internal/secrets"
)

// bomPrefix is the UTF-8 byte order mark written by some Windows editors.
var bomPrefix = []byte{0xEF, 0xBB, 0xBF}

// Config mirrors the relevant fields of ~/.gobot/config.json.
type Config struct {
	Agents     AgentsConfig     `json:"agents"`
	Channels   ChannelsConfig   `json:"channels"`
	Providers  ProvidersConfig  `json:"providers"`
	Tools      ToolsConfig      `json:"tools"`
	Strategic  StrategicConfig  `json:"strategic_edition"`
	Gateway    GatewayConfig    `json:"gateway"`
	Resilience ResilienceConfig `json:"resilience"`
}

type ResilienceConfig struct {
	CircuitBreakers map[string]BreakerConfig `json:"circuit_breakers"`
}

type BreakerConfig struct {
	MaxFailures uint32 `json:"max_failures"`
	Window      int    `json:"window_seconds"`  // countWindow
	Timeout     int    `json:"timeout_seconds"` // openTimeout
}

type AgentsConfig struct {
	Defaults    AgentDefaults               `json:"defaults"`
	Specialists map[string]SpecialistConfig `json:"specialists"`
}

type AgentDefaults struct {
	Model             string                 `json:"model"`
	Provider          string                 `json:"provider"`
	MaxTokens         int                    `json:"maxTokens"`
	MaxToolIterations int                    `json:"maxToolIterations"`
	MemoryWindow      int                    `json:"memoryWindow"`
	ContextPruning    ContextPruningConfig   `json:"contextPruning"`
	Compaction        CompactionPolicyConfig `json:"compaction"`
}

type ContextPruningConfig struct {
	TTL                string `json:"ttl"`
	KeepLastAssistants int    `json:"keepLastAssistants"`
}

type CompactionPolicyConfig struct {
	Strategy    string            `json:"strategy"`
	MemoryFlush MemoryFlushConfig `json:"memoryFlush"`
}

type MemoryFlushConfig struct {
	Prompt string `json:"prompt"`
}

type SpecialistConfig struct {
	Model    string `json:"model"`
	Provider string `json:"provider"`
}

type ChannelsConfig struct {
	Telegram TelegramConfig `json:"telegram"`
}

type ProvidersConfig struct {
	Gemini    GeminiConfig    `json:"gemini"`
	Anthropic AnthropicConfig `json:"anthropic"`
	OpenAI    OpenAIConfig    `json:"openai"`
	Google    GoogleConfig    `json:"google"`
}

type GeminiConfig struct {
	APIKey string `json:"apiKey"`
}

type AnthropicConfig struct {
	APIKey string `json:"apiKey"`
}

type OpenAIConfig struct {
	APIKey  string `json:"apiKey"`
	BaseURL string `json:"baseUrl,omitempty"`
}

type GoogleConfig struct {
	APIKey   string `json:"apiKey"`
	CustomCX string `json:"customCx"`
}

type TelegramConfig struct {
	Enabled   bool     `json:"enabled"`
	HITL      bool     `json:"hitl"`
	Token     string   `json:"token"`
	AllowFrom []string `json:"allowFrom"`
}

type GatewayConfig struct {
	Enabled bool   `json:"enabled"`
	Host    string `json:"host"`
	Port    int    `json:"port"`
}

// ExecConfig holds settings for the shell_exec tool.
type ExecConfig struct {
	Timeout int `json:"timeout"` // seconds; 0 means use tool default
}

// ToolsConfig maps to the top-level "tools" key in config.json.
type ToolsConfig struct {
	Exec       ExecConfig                 `json:"exec"`
	MCPServers map[string]MCPServerConfig `json:"mcpServers"`
}

type StrategicConfig struct {
	UserEmail         string              `json:"user_email"`
	StorageRoot       string              `json:"storage_root"`
	Mandate           string              `json:"mandate"`
	MaxToolIterations int                 `json:"max_tool_iterations,omitempty"`
	Observability     ObservabilityConfig `json:"observability"`
}

type ObservabilityConfig struct {
	ServiceName    string  `json:"service_name"`
	ServiceVersion string  `json:"service_version"`
	OTLPEndpoint   string  `json:"otlp_endpoint"`
	SamplingRate   float64 `json:"sampling_rate"`
}

// MemoryWindow returns the configured agent memory window (max context messages), defaulting to 50.
func (c *Config) MemoryWindow() int {
	if c.Agents.Defaults.MemoryWindow > 0 {
		return c.Agents.Defaults.MemoryWindow
	}
	return 50
}

// ContextPruning returns the configured context pruning policy.
func (c *Config) ContextPruning() ContextPruningConfig {
	return c.Agents.Defaults.ContextPruning
}

// Compaction returns the configured compaction policy.
func (c *Config) Compaction() CompactionPolicyConfig {
	return c.Agents.Defaults.Compaction
}

// MaxTokens returns the configured maximum output tokens, defaulting to 0 (API default).
func (c *Config) MaxTokens() int {
	if c.Agents.Defaults.MaxTokens > 0 {
		return c.Agents.Defaults.MaxTokens
	}
	return 0
}

// EffectiveMaxToolIterations returns the configured tool iteration cap,
// defaulting to 25 if unset or zero.
func (c *Config) EffectiveMaxToolIterations() int {
	if c.Strategic.MaxToolIterations > 0 {
		return c.Strategic.MaxToolIterations
	}
	return 25
}

// MCPServerConfig describes one MCP server entry under tools.mcpServers.
// The server name is the map key, not a field. Env values that are empty
// strings are resolved from DPAPI at runtime.
type MCPServerConfig struct {
	Command string            `json:"command"`
	Args    []string          `json:"args"`
	Env     map[string]string `json:"env"`
}

// StorageRoot returns the configured storage root, defaulting to D:\Gobot_Storage if it exists,
// or ~/gobot_data otherwise.
func (c *Config) StorageRoot() string {
	if c.Strategic.StorageRoot != "" {
		return c.Strategic.StorageRoot
	}
	// Strategic Edition Default: Prioritize D: drive on Windows if it exists.
	if _, err := os.Stat(`D:\Gobot_Storage`); err == nil {
		return `D:\Gobot_Storage`
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return `D:\Gobot_Storage`
	}
	return filepath.Join(home, "gobot_data")
}

// Breaker returns the configuration for a named circuit breaker, falling back to
// safe defaults if not configured: 5 failures, 60s window, 30s timeout.
func (c *Config) Breaker(name string) (maxFail uint32, window, timeout time.Duration) {
	if bc, ok := c.Resilience.CircuitBreakers[name]; ok {
		maxFail = bc.MaxFailures
		if bc.Window > 0 {
			window = time.Duration(bc.Window) * time.Second
		} else {
			window = 60 * time.Second
		}
		if bc.Timeout > 0 {
			timeout = time.Duration(bc.Timeout) * time.Second
		} else {
			timeout = 30 * time.Second
		}
		return maxFail, window, timeout
	}
	return 5, 60 * time.Second, 30 * time.Second
}

// Save marshals the config to JSON and writes it to the specified path.
func (c *Config) Save(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return fmt.Errorf("create config dir: %w", err)
	}
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal config: %w", err)
	}
	return os.WriteFile(path, data, 0600)
}

// SecretsRoot returns the path to the secrets directory under StorageRoot.
func (c *Config) SecretsRoot() string {
	return filepath.Join(c.StorageRoot(), "secrets")
}

// LogsRoot returns the path to the logs directory under StorageRoot.
func (c *Config) LogsRoot() string {
	return filepath.Join(c.StorageRoot(), "logs")
}

// LogPath returns the path to a specific log file under LogsRoot.
func (c *Config) LogPath(filename string) string {
	return filepath.Join(c.LogsRoot(), filename)
}

// DefaultModel returns the configured default model, falling back to gemini-3-flash-preview.
func (c *Config) DefaultModel() string {
	if c.Agents.Defaults.Model != "" {
		return c.Agents.Defaults.Model
	}
	return "gemini-3-flash-preview"
}

// DefaultProvider returns the configured default provider, defaulting to "gemini".
func (c *Config) DefaultProvider() string {
	p := c.Agents.Defaults.Provider
	if p == "" || p == "auto" {
		return "gemini"
	}
	return p
}

// SpecialistProvider returns the provider for a named specialist,
// falling back to DefaultProvider if unset or "auto".
func (c *Config) SpecialistProvider(name string) string {
	if s, ok := c.Agents.Specialists[name]; ok && s.Provider != "" && s.Provider != "auto" {
		return s.Provider
	}
	return c.DefaultProvider()
}

// WorkspacePath returns the path to a resource under {StorageRoot}/workspace/.
// Subpath elements are joined after the workspace directory.
func (c *Config) WorkspacePath(subpath ...string) string {
	parts := append([]string{c.StorageRoot(), "workspace"}, subpath...)
	return filepath.Join(parts...)
}

// GeminiAPIKey returns the Gemini API key. Priority order:
// 1. config.json field
// 2. DPAPI secrets store (gemini_api_key)
// 3. GEMINI_API_KEY environment variable (for CI / DPAPI-free environments)
func (c *Config) GeminiAPIKey() string {
	if c.Providers.Gemini.APIKey != "" {
		return c.Providers.Gemini.APIKey
	}
	store := secrets.NewSecretsStore(c.StorageRoot())
	if val, _ := store.Get("gemini_api_key"); val != "" { // Error ignored; fall back to environment variable.
		return val
	}
	return os.Getenv("GEMINI_API_KEY")
}

// AnthropicAPIKey returns the Anthropic API key. Priority order:
// 1. config.json field
// 2. DPAPI secrets store (anthropic_api_key)
// 3. ANTHROPIC_API_KEY environment variable
func (c *Config) AnthropicAPIKey() string {
	if c.Providers.Anthropic.APIKey != "" {
		return c.Providers.Anthropic.APIKey
	}
	store := secrets.NewSecretsStore(c.StorageRoot())
	if val, _ := store.Get("anthropic_api_key"); val != "" { // Error ignored; fall back to environment variable.
		return val
	}
	return os.Getenv("ANTHROPIC_API_KEY")
}

// OpenAIAPIKey returns the OpenAI API key. Priority order:
// 1. config.json field
// 2. DPAPI secrets store (openai_api_key)
// 3. OPENAI_API_KEY environment variable
func (c *Config) OpenAIAPIKey() string {
	if c.Providers.OpenAI.APIKey != "" {
		return c.Providers.OpenAI.APIKey
	}
	store := secrets.NewSecretsStore(c.StorageRoot())
	if val, _ := store.Get("openai_api_key"); val != "" { // Error ignored; fall back to environment variable.
		return val
	}
	return os.Getenv("OPENAI_API_KEY")
}

// OpenAIBaseURL returns the OpenAI base URL. Priority order:
// 1. config.json field
// 2. DPAPI secrets store (openai_base_url)
// 3. OPENAI_BASE_URL environment variable
func (c *Config) OpenAIBaseURL() string {
	if c.Providers.OpenAI.BaseURL != "" {
		return c.Providers.OpenAI.BaseURL
	}
	store := secrets.NewSecretsStore(c.StorageRoot())
	if val, _ := store.Get("openai_base_url"); val != "" { // Error ignored; fall back to environment variable.
		return val
	}
	return os.Getenv("OPENAI_BASE_URL")
}

// GoogleAPIKey returns the Google Custom Search API key. Priority order:
// 1. config.json field
// 2. DPAPI secrets store (google_api_key)
// 3. GOOGLE_API_KEY environment variable
func (c *Config) GoogleAPIKey() string {
	if c.Providers.Google.APIKey != "" {
		return c.Providers.Google.APIKey
	}
	store := secrets.NewSecretsStore(c.StorageRoot())
	if val, _ := store.Get("google_api_key"); val != "" {
		return val
	}
	return os.Getenv("GOOGLE_API_KEY")
}

// GoogleCX returns the Google Custom Search Engine ID (CX). Priority order:
// 1. config.json field
// 2. DPAPI secrets store (google_cx)
// 3. GOOGLE_CX environment variable
func (c *Config) GoogleCX() string {
	if c.Providers.Google.CustomCX != "" {
		return c.Providers.Google.CustomCX
	}
	store := secrets.NewSecretsStore(c.StorageRoot())
	if val, _ := store.Get("google_cx"); val != "" {
		return val
	}
	return os.Getenv("GOOGLE_CX")
}

// TelegramToken returns the Telegram bot token from config,
// falling back to the DPAPI secrets store or TELEGRAM_BOT_TOKEN environment variable.
func (c *Config) TelegramToken() string {
	if t := c.Channels.Telegram.Token; t != "" {
		return t
	}
	store := secrets.NewSecretsStore(c.StorageRoot())
	if val, _ := store.Get("telegram_token"); val != "" {
		return val
	}
	return os.Getenv("TELEGRAM_BOT_TOKEN")
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
		if v, _ := store.Get(key); v != "" {
			env[varName] = v
		}
	}
	return env
}

// ExecTimeout returns the shell tool execution timeout, defaulting to 2 minutes.
func (c *Config) ExecTimeout() time.Duration {
	if c.Tools.Exec.Timeout > 0 {
		return time.Duration(c.Tools.Exec.Timeout) * time.Second
	}
	return 2 * time.Minute
}

// HumanInTheLoop returns true if the human-in-the-loop approval framework is enabled.
func (c *Config) HumanInTheLoop() bool {
	return c.Channels.Telegram.HITL
}

// DefaultConfigPath returns ~/.gobot/config.json.
func DefaultConfigPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".gobot", "config.json")
}

// Load reads and parses the config from the default path.
func Load() (*Config, error) {
	return LoadFrom(DefaultConfigPath())
}

// LoadFrom reads and parses a config file, stripping a leading UTF-8 BOM if present.
func LoadFrom(path string) (*Config, error) {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return &Config{}, nil
		}
		return nil, fmt.Errorf("open config %s: %w", path, err)
	}
	defer f.Close()

	return decode(f)
}

// decode strips an optional BOM then JSON-decodes the reader into Config.
func decode(r io.Reader) (*Config, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return nil, fmt.Errorf("read config: %w", err)
	}

	// Strip UTF-8 BOM if present
	if len(data) >= 3 &&
		data[0] == bomPrefix[0] &&
		data[1] == bomPrefix[1] &&
		data[2] == bomPrefix[2] {
		data = data[3:]
	}

	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}
	return &cfg, nil
}
