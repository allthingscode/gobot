// Package config loads the gobot config.json with BOM stripping and struct validation.
package config

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/allthingscode/gobot/internal/logattr"
	"github.com/allthingscode/gobot/internal/secrets"
)

// BOMPrefix is the UTF-8 byte order mark written by some Windows editors.
//
//nolint:gochecknoglobals // Immutable constant for BOM detection
var BOMPrefix = []byte{0xEF, 0xBB, 0xBF}

// LoggingConfig controls log persistence, rotation, and formatting.
type LoggingConfig struct {
	Level      string `json:"level"`      // "DEBUG", "INFO", "WARN", "ERROR"
	Format     string `json:"format"`     // "text", "json"
	MaxSizeMB  int    `json:"maxSizeMB"`  // default: 50
	MaxBackups int    `json:"maxBackups"` // default: 5
	MaxAgeDays int    `json:"maxAgeDays"` // default: 30
	Compress   bool   `json:"compress"`   // default: true
}

// Config mirrors the relevant fields of ~/.gobot/config.json.
type Config struct {
	Agents     AgentsConfig     `json:"agents"`
	Channels   ChannelsConfig   `json:"channels"`
	Providers  ProvidersConfig  `json:"providers"`
	Tools      ToolsConfig      `json:"tools"`
	Runtime    RuntimeConfig    `json:"runtime"`
	Gateway    GatewayConfig    `json:"gateway"`
	Resilience ResilienceConfig `json:"resilience"`
	Context    ContextConfig    `json:"context"`
	Cron       CronConfig       `json:"cron"`
	Heartbeat  HeartbeatConfig  `json:"heartbeat"`
	Logging    LoggingConfig    `json:"logging"`
	Browser    BrowserConfig    `json:"browser"`

	// projectRoot is the directory where the bot was started (source code).
	// Not exported to avoid appearing in config.json.
	projectRoot string
}

// ProjectRoot returns the project source directory.
func (c *Config) ProjectRoot() string {
	return c.projectRoot
}

// SetProjectRoot sets the project source directory.
func (c *Config) SetProjectRoot(root string) {
	c.projectRoot = root
}

type BrowserConfig struct {
	DebugPort int  `json:"debugPort"` // 0 = disabled; non-zero = attach to existing Chrome
	Headless  bool `json:"headless"`  // true = launch headless Chrome
}

type CronConfig struct {
	Enabled bool `json:"enabled"`
	Tasks   []struct {
		Name     string `json:"name"`
		Schedule string `json:"schedule"`
	} `json:"tasks,omitempty"`
}

type HeartbeatConfig struct {
	Enabled  bool   `json:"enabled"`
	Interval string `json:"interval"` // Go duration string, e.g. "30s"
}

type ResilienceConfig struct {
	CircuitBreakers map[string]BreakerConfig `json:"circuitBreakers"`
}

type BreakerConfig struct {
	MaxFailures uint32 `json:"maxFailures"`
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
	SessionTokenBudget     int `json:"sessionTokenBudget"`
	CompactionSummaryTurns int `json:"compactionSummaryTurns"`
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
	Gemini     GeminiConfig    `json:"gemini"`
	Anthropic  AnthropicConfig `json:"anthropic"`
	OpenAI     OpenAIConfig    `json:"openai"`
	OpenRouter OpenAIConfig    `json:"openrouter"`
	Google     GoogleConfig    `json:"google"`
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
	DashboardEnabled bool   `json:"dashboardEnabled"`
	AuthToken        string `json:"authToken"`
	Host             string `json:"host"`
	Port             int    `json:"port"`
	WebAddr          string `json:"webAddr"` // F-111
}

// ExecConfig holds settings for the shell_exec tool.
type ExecConfig struct {
	Timeout int `json:"timeout"` // seconds; 0 means use tool default
}

// ToolsConfig maps to the top-level "tools" key in config.json.
type ToolsConfig struct {
	Exec       ExecConfig                 `json:"exec"`
	MCPServers map[string]MCPServerConfig `json:"mcpServers"`
	HighRisk   []string                   `json:"highRisk"`
}

type RuntimeConfig struct {
	UserEmail           string              `json:"user_email"`
	UserChatID          int64               `json:"user_chat_id"`
	StorageRoot         string              `json:"storage_root"`
	MaxToolIterations   int                 `json:"max_tool_iterations,omitempty"`
	IdempotencyTTL      string              `json:"idempotencyTTL,omitempty"` // e.g., "24h", "72h"
	VectorSearchEnabled bool                `json:"vector_search_enabled"`    // F-030
	MultiUserEnabled    bool                `json:"multi_user_enabled"`       // F-073
	GmailReadonly       bool                `json:"gmail_readonly"`           // when false, search_gmail and read_gmail tools are not registered
	GoogleScopes        []string            `json:"google_scopes,omitempty"`  // OAuth scopes requested during reauth; defaults to full task/calendar/gmail set
	Observability       ObservabilityConfig `json:"observability"`
	TemplatesPath       string              `json:"templates_path,omitempty"`        // Custom directory for email templates
	CustomCSSPath       string              `json:"custom_css_path,omitempty"`       // Custom CSS file for email styling override
	Routing             RoutingConfig       `json:"routing"`                         // F-102
	PolicyFilePath      string              `json:"policy_file_path,omitempty"`      // F-103
	EmbeddingModel      string              `json:"embedding_model,omitempty"`       // B-049
	VectorIndexInterval string              `json:"vector_index_interval,omitempty"` // F-142, e.g. "24h"
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
	return c.Runtime.MultiUserEnabled
}

// VectorSearchEnabled returns true if semantic hybrid search is enabled (F-030).
func (c *Config) VectorSearchEnabled() bool {
	return c.Runtime.VectorSearchEnabled
}

// VectorIndexInterval returns the interval for the automatic workspace
// re-indexing job (F-142), defaulting to 24h. If the configured value cannot
// be parsed as a Go duration, a warning is logged and the default is used.
func (c *Config) VectorIndexInterval() time.Duration {
	const defaultInterval = 24 * time.Hour
	raw := c.Runtime.VectorIndexInterval
	if raw == "" {
		return defaultInterval
	}
	d, err := time.ParseDuration(raw)
	if err != nil || d <= 0 {
		slog.Warn("config: invalid vector_index_interval, using default", "value", raw, "default", defaultInterval)
		return defaultInterval
	}
	return d
}

// TemplatesPath returns the custom directory for email templates, if configured.
func (c *Config) TemplatesPath() string {
	return c.Runtime.TemplatesPath
}

// GoogleScopes returns the OAuth2 scopes to request during reauth.
// Defaults to the full task/calendar/gmail set when not configured.
func (c *Config) GoogleScopes() []string {
	if len(c.Runtime.GoogleScopes) > 0 {
		return c.Runtime.GoogleScopes
	}
	return []string{
		"https://www.googleapis.com/auth/tasks",
		"https://www.googleapis.com/auth/calendar",
		"https://mail.google.com/",
	}
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
	if c.Runtime.IdempotencyTTL != "" {
		if ttl, err := time.ParseDuration(c.Runtime.IdempotencyTTL); err == nil && ttl > 0 {
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
	if c.Runtime.MaxToolIterations > 0 {
		return c.Runtime.MaxToolIterations
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
// 1. config.json (runtime.storage_root)
// 2. GOBOT_STORAGE environment variable (explicit override; existing installs unchanged)
// 3. $GOBOT_HOME/data (derived default, so a single GOBOT_HOME is the only path to set)
// 4. ~/gobot_data (portable default when neither GOBOT_STORAGE nor GOBOT_HOME is set).
//
// An install that sets GOBOT_HOME but not GOBOT_STORAGE resolves data under $GOBOT_HOME/data; set
// GOBOT_STORAGE explicitly to pin a separate location. GOBOT_STORAGE-set installs never relocate.
func (c *Config) StorageRoot() string {
	if c.Runtime.StorageRoot != "" {
		return c.Runtime.StorageRoot
	}
	if envRoot := os.Getenv("GOBOT_STORAGE"); envRoot != "" {
		return envRoot
	}
	if gobotHome := os.Getenv("GOBOT_HOME"); gobotHome != "" {
		return filepath.Join(gobotHome, "data")
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

// Marshal returns the config as indented JSON with a leading UTF-8 BOM.
func (c *Config) Marshal() ([]byte, error) {
	data, err := json.MarshalIndent(c, "", "    ")
	if err != nil {
		return nil, fmt.Errorf("marshal config: %w", err)
	}

	finalData := make([]byte, 0, len(BOMPrefix)+len(data))
	finalData = append(finalData, BOMPrefix...)
	finalData = append(finalData, data...)
	return finalData, nil
}

// Save marshals the config to JSON and writes it to the specified path.
func (c *Config) Save(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create config dir: %w", err)
	}
	data, err := c.Marshal()
	if err != nil {
		return err
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return fmt.Errorf("write config file: %w", err)
	}
	return nil
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
	if c.Runtime.EmbeddingModel != "" {
		return c.Runtime.EmbeddingModel
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

// HeartbeatInterval returns the configured heartbeat interval, defaulting to 15 minutes.
func (c *Config) HeartbeatInterval() time.Duration {
	return parseDurationOrDefault(c.Heartbeat.Interval, 15*time.Minute)
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

// LogLevel returns the configured logging level.
func (c *Config) LogLevel() slog.Level {
	lvl := strings.ToUpper(c.Logging.Level)
	switch lvl {
	case "DEBUG":
		return slog.LevelDebug
	case "WARN":
		return slog.LevelWarn
	case "ERROR":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}

// LogFormat returns the configured logging format ("text" or "json").
func (c *Config) LogFormat() string {
	if strings.ToLower(c.Logging.Format) == "json" {
		return "json"
	}
	return "text"
}

// TelemetryEnabled returns true if OTel is enabled.
func (c *Config) TelemetryEnabled() bool {
	return c.Runtime.Observability.OTLPEndpoint != ""
}

// OTelEndpoint returns the OTel collector endpoint.
func (c *Config) OTelEndpoint() string {
	return c.Runtime.Observability.OTLPEndpoint
}

// HighRiskTools returns the list of tools that require human approval.
func (c *Config) HighRiskTools() []string {
	return c.Tools.HighRisk
}

// PolicyFilePath returns the configured tool policy file path.
func (c *Config) PolicyFilePath() string {
	return c.Runtime.PolicyFilePath
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
		data[0] == BOMPrefix[0] &&
		data[1] == BOMPrefix[1] &&
		data[2] == BOMPrefix[2] {
		data = data[3:]
	}

	data = normalizeLegacyKeys(data)

	var cfg Config
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&cfg); err != nil {
		return nil, fmt.Errorf("config: invalid field or syntax: %w", err)
	}
	applyGatewayDefaults(&cfg)
	return &cfg, nil
}

// applyGatewayDefaults enforces local-safe binding defaults (F-139).
// An empty host binds to all interfaces (0.0.0.0); for a single-user local
// assistant we default to loopback. Explicit values (including 0.0.0.0) are
// preserved so an operator can still opt in to external binding.
func applyGatewayDefaults(cfg *Config) {
	if cfg.Gateway.Host == "" {
		cfg.Gateway.Host = "127.0.0.1"
	}
	if cfg.Gateway.WebAddr == "" && cfg.Gateway.DashboardEnabled {
		cfg.Gateway.WebAddr = "127.0.0.1:0"
	}
}

// legacyKeyRenames is the SINGLE source of truth mapping deprecated snake_case config
// keys to their canonical camelCase form (C-326). The map key is the dot-joined path of
// the CONTAINING object (root object = ""); a trailing ".*" segment matches every entry
// of a JSON object used as a map (e.g. a named circuit breaker under
// resilience.circuitBreakers). The loader rewrites legacy keys to canonical before strict
// decoding so existing configs keep working during the deprecation window, while
// Config.Save only ever emits the canonical key. To end the deprecation window, delete
// this map and the normalizeLegacyKeys call in decode in one commit.
//
//nolint:gochecknoglobals // immutable lookup table for the key-deprecation window
var legacyKeyRenames = map[string]map[string]string{
	"": {
		// C-327: the legacy "strategic_edition" block was renamed to the neutral "runtime".
		"strategic_edition": "runtime",
	},
	"logging": {
		"max_size_mb":  "maxSizeMB",
		"max_backups":  "maxBackups",
		"max_age_days": "maxAgeDays",
	},
	"browser": {
		"debug_port": "debugPort",
	},
	"resilience": {
		"circuit_breakers": "circuitBreakers",
	},
	"resilience.circuitBreakers.*": {
		"max_failures": "maxFailures",
	},
	"context": {
		"session_token_budget":     "sessionTokenBudget",
		"compaction_summary_turns": "compactionSummaryTurns",
	},
	"gateway": {
		"dashboard_enabled": "dashboardEnabled",
		"auth_token":        "authToken",
		"web_addr":          "webAddr",
	},
	"tools": {
		"high_risk": "highRisk",
	},
}

// normalizeLegacyKeys rewrites deprecated snake_case keys to their canonical camelCase
// form (see legacyKeyRenames) so a config written with the old names still loads. It
// returns the input unchanged when the payload is not a JSON object (the strict decoder
// then reports the real error) or when no legacy key is present.
func normalizeLegacyKeys(data []byte) []byte {
	var root map[string]json.RawMessage
	if err := json.Unmarshal(data, &root); err != nil {
		return data
	}
	if !renameKeysAtPath(root, "", map[string]bool{}) {
		return data
	}
	out, err := json.Marshal(root)
	if err != nil {
		return data
	}
	return out
}

// renameKeysAtPath applies the rules registered for obj's own path, then descends only
// into child objects that (or whose ".*" map entries) have their own rules. Returns true
// if any key was renamed in the subtree.
func renameKeysAtPath(obj map[string]json.RawMessage, path string, warned map[string]bool) bool {
	changed := false
	if renames, ok := legacyKeyRenames[path]; ok {
		changed = applyRenames(obj, path, renames, warned)
	}
	for childKey, childRaw := range obj {
		if descendChild(obj, childKey, childRaw, childPathOf(path, childKey), warned) {
			changed = true
		}
	}
	return changed
}

func childPathOf(path, childKey string) string {
	if path == "" {
		return childKey
	}
	return path + "." + childKey
}

// hasRuleForPath reports whether any rename rule applies at path, either directly or to
// the entries of a map at that path (".*").
func hasRuleForPath(path string) bool {
	if _, ok := legacyKeyRenames[path]; ok {
		return true
	}
	_, ok := legacyKeyRenames[path+".*"]
	return ok
}

// normalizeChild applies the direct and ".*" map-entry rules registered for childPath to
// an already-decoded child object. Returns true if anything changed.
func normalizeChild(child map[string]json.RawMessage, childPath string, warned map[string]bool) bool {
	changed := false
	if _, ok := legacyKeyRenames[childPath]; ok && renameKeysAtPath(child, childPath, warned) {
		changed = true
	}
	if wildRenames, ok := legacyKeyRenames[childPath+".*"]; ok && renameMapEntries(child, childPath+".*", wildRenames, warned) {
		changed = true
	}
	return changed
}

// descendChild recurses into a single child object when a rule applies at childPath,
// re-marshaling it back into parent on change.
func descendChild(parent map[string]json.RawMessage, childKey string, childRaw json.RawMessage, childPath string, warned map[string]bool) bool {
	if !hasRuleForPath(childPath) {
		return false
	}
	var child map[string]json.RawMessage
	if err := json.Unmarshal(childRaw, &child); err != nil || child == nil {
		return false
	}
	if !normalizeChild(child, childPath, warned) {
		return false
	}
	if rm, err := json.Marshal(child); err == nil {
		parent[childKey] = rm
	}
	return true
}

// renameMapEntries applies renames to every value of a JSON object used as a map (e.g.
// each named circuit breaker), re-marshaling changed entries in place.
func renameMapEntries(m map[string]json.RawMessage, path string, renames map[string]string, warned map[string]bool) bool {
	changed := false
	for k, raw := range m {
		var inner map[string]json.RawMessage
		if err := json.Unmarshal(raw, &inner); err != nil || inner == nil {
			continue
		}
		if applyRenames(inner, path, renames, warned) {
			if rm, err := json.Marshal(inner); err == nil {
				m[k] = rm
				changed = true
			}
		}
	}
	return changed
}

// applyRenames moves each present legacy key to its canonical key within obj, logging
// exactly one WARN per legacy key per load. When both keys are present the canonical
// value wins and the legacy key is dropped (with a warning). Returns true if modified.
func applyRenames(obj map[string]json.RawMessage, path string, renames map[string]string, warned map[string]bool) bool {
	changed := false
	for legacy, canonical := range renames {
		val, present := obj[legacy]
		if !present {
			continue
		}
		warnKey := path + "/" + legacy
		if _, hasCanonical := obj[canonical]; hasCanonical {
			if !warned[warnKey] {
				slog.Warn("config: deprecated key ignored because the canonical key is also present; remove the deprecated key",
					"deprecated_key", legacy, "canonical_key", canonical, "section", path)
				warned[warnKey] = true
			}
		} else {
			obj[canonical] = val
			if !warned[warnKey] {
				slog.Warn("config: deprecated key in use; rename it to the canonical key",
					"deprecated_key", legacy, "canonical_key", canonical, "section", path)
				warned[warnKey] = true
			}
		}
		delete(obj, legacy)
		changed = true
	}
	return changed
}
