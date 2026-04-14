// Package config loads the gobot config.json with BOM stripping and struct validation.
package config

import (
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/allthingscode/gobot/internal/secrets"
)

// bomPrefix is the UTF-8 byte order mark written by some Windows editors.
//
//nolint:gochecknoglobals // Immutable constant for BOM detection
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
	Context    ContextConfig    `json:"context"`
}

type ResilienceConfig struct {
	CircuitBreakers map[string]BreakerConfig `json:"circuit_breakers"`
}

type BreakerConfig struct {
	MaxFailures uint32 `json:"max_failures"`
	Window      string `json:"window"`  // Go duration string, e.g. "60s"
	Timeout     string `json:"timeout"` // Go duration string, e.g. "30s"
}

type AgentsConfig struct {
	Defaults    AgentDefaults               `json:"defaults"`
	Specialists map[string]SpecialistConfig `json:"specialists"`
}

type AgentDefaults struct {
	Model              string                 `json:"model"`
	Provider           string                 `json:"provider"`
	MaxTokens          int                    `json:"maxTokens"`
	MaxToolIterations  int                    `json:"maxToolIterations"`
	MaxToolResultBytes int                    `json:"maxToolResultBytes"`
	LockTimeoutSeconds int                    `json:"lockTimeoutSeconds"`
	MemoryWindow       int                    `json:"memoryWindow"`
	ContextPruning     ContextPruningConfig   `json:"contextPruning"`
	Compaction         CompactionPolicyConfig `json:"compaction"`
}

type ContextPruningConfig struct {
	TTL                string `json:"ttl"`
	KeepLastAssistants int    `json:"keepLastAssistants"`
}

type ContextConfig struct {
	SessionTokenBudget     int `json:"session_token_budget"`
	CompactionSummaryTurns int `json:"compaction_summary_turns"`
}

// DefaultSummarizationThreshold is the default threshold for context summarization (70%).
const DefaultSummarizationThreshold = 0.7

// SummarizationConfig controls automatic context summarization before pruning.
type SummarizationConfig struct {
	Enabled   bool    `json:"enabled"`
	Model     string  `json:"model"`
	Threshold float64 `json:"threshold"`
}

type CompactionPolicyConfig struct {
	Strategy      string              `json:"strategy"`
	MemoryFlush   MemoryFlushConfig   `json:"memoryFlush"`
	Summarization SummarizationConfig `json:"summarization"`
}

// IsSummarizationEnabled returns true if summarization is enabled.
func (s SummarizationConfig) IsSummarizationEnabled() bool {
	return s.Enabled
}

// SummarizationThreshold returns the configured threshold, or the default (70%) if unset.
func (s SummarizationConfig) SummarizationThreshold() float64 {
	if s.Threshold > 0 {
		return s.Threshold
	}
	return DefaultSummarizationThreshold
}

// SummarizationModel returns the configured model, falling back to the provided default if empty.
func (s SummarizationConfig) SummarizationModel(defaultModel string) string {
	if s.Model != "" {
		return s.Model
	}
	return defaultModel
}

type MemoryFlushConfig struct {
	Prompt                  string   `json:"prompt"`
	TTL                     string   `json:"ttl"` // e.g., "2160h" for 90 days; empty means no cleanup
	GlobalTTL               string   `json:"globalTTL"`
	GlobalNamespacePatterns []string `json:"globalNamespacePatterns"`
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
	Enabled          bool   `json:"enabled"`
	DashboardEnabled bool   `json:"dashboard_enabled"`
	AuthToken        string `json:"auth_token"`
	Host             string `json:"host"`
	Port             int    `json:"port"`
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
	UserEmail           string              `json:"user_email"`
	StorageRoot         string              `json:"storage_root"`
	MaxToolIterations   int                 `json:"max_tool_iterations,omitempty"`
	IdempotencyTTL      string              `json:"idempotencyTTL,omitempty"` // e.g., "24h", "72h"
	VectorSearchEnabled bool                `json:"vector_search_enabled"`    // F-030
	MultiUserEnabled    bool                `json:"multi_user_enabled"`       // F-073
	Observability       ObservabilityConfig `json:"observability"`
	TemplatesPath       string              `json:"templates_path,omitempty"`   // Custom directory for email templates
	Routing             RoutingConfig       `json:"routing"`                    // F-102
	PolicyFilePath      string              `json:"policy_file_path,omitempty"` // F-103
	EmbeddingModel      string              `json:"embedding_model,omitempty"`  // B-049
}

type RoutingConfig struct {
	Enabled         bool   `json:"enabled"`
	ManagerModel    string `json:"manager_model"`
	ManagerProvider string `json:"manager_provider,omitempty"` // defaults to main provider if empty
}

type ObservabilityConfig struct {
	ServiceName    string  `json:"service_name"`
	ServiceVersion string  `json:"service_version"`
	OTLPEndpoint   string  `json:"otlp_endpoint"`
	SamplingRate   float64 `json:"sampling_rate"`
	DevMode        bool    `json:"dev_mode"`
}

// MultiUserEnabled returns true if multi-user workspace isolation is enabled (F-073).
func (c *Config) MultiUserEnabled() bool {
	return c.Strategic.MultiUserEnabled
}

// VectorSearchEnabled returns true if semantic hybrid search is enabled (F-030).
func (c *Config) VectorSearchEnabled() bool {
	return c.Strategic.VectorSearchEnabled
}

// TemplatesPath returns the custom directory for email templates, if configured.
func (c *Config) TemplatesPath() string {
	return c.Strategic.TemplatesPath
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

// SessionTokenBudget returns the per-session token budget for compaction,
// defaulting to 80000 if unset or zero.
func (c *Config) SessionTokenBudget() int {
	if c.Context.SessionTokenBudget > 0 {
		return c.Context.SessionTokenBudget
	}
	return 80000
}

// CompactionSummaryTurns returns how many oldest turns to summarize per compaction
// pass, defaulting to 20 if unset or zero.
func (c *Config) CompactionSummaryTurns() int {
	if c.Context.CompactionSummaryTurns > 0 {
		return c.Context.CompactionSummaryTurns
	}
	return 20
}

// EffectiveIdempotencyTTL returns the configured idempotency key TTL,
// defaulting to 24 hours if unset or invalid.
func (c *Config) EffectiveIdempotencyTTL() time.Duration {
	if c.Strategic.IdempotencyTTL != "" {
		if ttl, err := time.ParseDuration(c.Strategic.IdempotencyTTL); err == nil && ttl > 0 {
			return ttl
		}
	}
	return 24 * time.Hour
}

// MaxTokens returns the configured maximum output tokens, defaulting to 0 (API default).
func (c *Config) MaxTokens() int {
	if c.Agents.Defaults.MaxTokens > 0 {
		return c.Agents.Defaults.MaxTokens
	}
	return 0
}

// MaxToolResultBytes returns the configured maximum tool result size in bytes,
// defaulting to 32768 (32KB). Zero or negative means no limit.
func (c *Config) MaxToolResultBytes() int {
	if c.Agents.Defaults.MaxToolResultBytes != 0 {
		return c.Agents.Defaults.MaxToolResultBytes
	}
	return 32768
}

// LockTimeoutDuration returns the configured session lock timeout,
// defaulting to 120 seconds if zero or unset.
func (c *Config) LockTimeoutDuration() time.Duration {
	if c.Agents.Defaults.LockTimeoutSeconds > 0 {
		return time.Duration(c.Agents.Defaults.LockTimeoutSeconds) * time.Second
	}
	return 120 * time.Second
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

// StorageRoot returns the configured storage root.
// Priority:
// 1. config.json (strategic_edition.storage_root)
// 2. GOBOT_STORAGE environment variable
// 3. ~/gobot_data (portable default).
func (c *Config) StorageRoot() string {
	if c.Strategic.StorageRoot != "" {
		return c.Strategic.StorageRoot
	}
	if envRoot := os.Getenv("GOBOT_STORAGE"); envRoot != "" {
		return envRoot
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "gobot_storage" // last resort fallback to current dir
	}
	return filepath.Join(home, "gobot_data")
}

// Breaker returns the configuration for a named circuit breaker, falling back to
// safe defaults if not configured: 5 failures, 60s window, 30s timeout.
func (c *Config) Breaker(name string) (maxFail uint32, window, timeout time.Duration) {
	if bc, ok := c.Resilience.CircuitBreakers[name]; ok {
		maxFail = bc.MaxFailures
		window = parseDurationOrDefault(bc.Window, 60*time.Second)
		timeout = parseDurationOrDefault(bc.Timeout, 30*time.Second)
		return maxFail, window, timeout
	}
	return 5, 60 * time.Second, 30 * time.Second
}

func parseDurationOrDefault(s string, defaultVal time.Duration) time.Duration {
	if s == "" {
		return defaultVal
	}
	d, err := time.ParseDuration(s)
	if err != nil || d <= 0 {
		return defaultVal
	}
	return d
}

// Save marshals the config to JSON and writes it to the specified path.
func (c *Config) Save(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create config dir: %w", err)
	}
	data, err := json.MarshalIndent(c, "", "    ")
	if err != nil {
		return fmt.Errorf("marshal config: %w", err)
	}

	// Prepend UTF-8 BOM for Windows compatibility as per project mandate
	finalData := make([]byte, 0, len(bomPrefix)+len(data))
	finalData = append(finalData, bomPrefix...)
	finalData = append(finalData, data...)
	return os.WriteFile(path, finalData, 0o600)
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

// EmbeddingModel returns the configured embedding model name,
// falling back to "text-embedding-004" if unset or empty.
func (c *Config) EmbeddingModel() string {
	if c.Strategic.EmbeddingModel != "" {
		return c.Strategic.EmbeddingModel
	}
	return "text-embedding-004"
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
// If MultiUserEnabled is true and userID is non-empty, the path is scoped to
// {StorageRoot}/workspace/users/{userID}/.
// Subpath elements are joined after the workspace directory.
func (c *Config) WorkspacePath(userID string, subpath ...string) string {
	base := filepath.Join(c.StorageRoot(), "workspace")
	if c.MultiUserEnabled() && userID != "" {
		base = filepath.Join(base, "users", userID)
	}
	parts := append([]string{base}, subpath...)
	return filepath.Join(parts...)
}

// resolveSecret returns the first non-empty value from: configVal -> secrets store
// (looked up by storeKey) -> environment variable (envKey).
// store is passed in so callers can share a single SecretsStore instance.
func (c *Config) resolveSecret(store *secrets.SecretsStore, configVal, storeKey, envKey string) string {
	if configVal != "" {
		return configVal
	}
	val, err := store.Get(storeKey)
	if err != nil {
		slog.Warn("secrets store lookup failed, falling back to env", "key", storeKey, "err", err)
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
			slog.Warn("secrets store lookup failed, falling back to env", "key", key, "err", err)
		}
		if v != "" {
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

// PolicyFilePath returns the configured tool policy file path.
func (c *Config) PolicyFilePath() string {
	return c.Strategic.PolicyFilePath
}

// DefaultConfigPath returns ~/.gobot/config.json.
func DefaultConfigPath() string {
	if h := os.Getenv("GOBOT_HOME"); h != "" {
		return filepath.Join(h, ".gobot", "config.json")
	}
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
	defer func() { _ = f.Close() }()

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
