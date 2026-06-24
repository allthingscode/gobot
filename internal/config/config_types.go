package config

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

// MCPServerConfig describes one MCP server entry under tools.mcpServers.
// The server name is the map key, not a field. Env values that are empty
// strings are resolved from DPAPI at runtime.
type MCPServerConfig struct {
	Command string            `json:"command"`
	Args    []string          `json:"args"`
	Env     map[string]string `json:"env"`
}
