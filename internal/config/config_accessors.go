package config

import (
	"log/slog"
	"strings"
	"time"
)

// DefaultSummarizationThreshold is the default threshold for context summarization (70%).
const DefaultSummarizationThreshold = 0.7

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
