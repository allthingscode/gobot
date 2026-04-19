// Package config provides configuration loading and validation.
package config

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Severity represents the criticality of a validation error.
type Severity string

const (
	SeverityCritical Severity = "CRITICAL"
	SeverityWarning  Severity = "WARNING"
)

// ValidationError represents a single validation failure.
type ValidationError struct {
	Field    string
	Message  string
	Remedy   string
	Severity Severity
}

func (v ValidationError) Error() string {
	if v.Remedy != "" {
		return fmt.Sprintf("%s: %s (fix: %s)", v.Field, v.Message, v.Remedy)
	}
	return fmt.Sprintf("%s: %s", v.Field, v.Message)
}

// ValidationResult holds all validation errors.
type ValidationResult struct {
	Errors []ValidationError
}

// HasErrors returns true if there are any validation errors.
func (r *ValidationResult) HasErrors() bool {
	return len(r.Errors) > 0
}

// HasCritical returns true if there are any critical validation errors.
func (r *ValidationResult) HasCritical() bool {
	for _, e := range r.Errors {
		if e.Severity == SeverityCritical {
			return true
		}
	}
	return false
}

// CriticalErrors returns only critical validation errors.
func (r *ValidationResult) CriticalErrors() []ValidationError {
	var critical []ValidationError
	for _, e := range r.Errors {
		if e.Severity == SeverityCritical {
			critical = append(critical, e)
		}
	}
	return critical
}

// Validator performs configuration validation.
type Validator struct {
	cfg *Config
}

// NewValidator creates a new validator for the given config.
func NewValidator(cfg *Config) *Validator {
	if cfg == nil {
		cfg = &Config{} // Avoid nil dereference
	}
	return &Validator{cfg: cfg}
}

// Validate performs all validation checks and returns the result.
func (v *Validator) Validate() *ValidationResult {
	result := &ValidationResult{}

	v.validateStorageRoot(result)
	v.validateWorkspace(result)
	v.validateAPIKeys(result)
	v.validateTelegram(result)
	v.validatePaths(result)
	v.validateDiskSpace(result)
	v.validateAgentDefaults(result)
	v.validateStrategic(result)
	v.validateResilience(result)

	return result
}

func (v *Validator) validateResilience(result *ValidationResult) {
	for name, bc := range v.cfg.Resilience.CircuitBreakers {
		v.validateTTL(fmt.Sprintf("resilience.circuit_breakers.%s.window", name), bc.Window, result)
		v.validateTTL(fmt.Sprintf("resilience.circuit_breakers.%s.timeout", name), bc.Timeout, result)
	}
}

func (v *Validator) validateAgentDefaults(result *ValidationResult) {
	// Validate Context Pruning TTL
	v.validateTTL("agents.defaults.contextPruning.ttl", v.cfg.Agents.Defaults.ContextPruning.TTL, result)

	// Validate Compaction Memory Flush TTL
	v.validateTTL("agents.defaults.compaction.memoryFlush.ttl", v.cfg.Agents.Defaults.Compaction.MemoryFlush.TTL, result)

	// Validate Lock Timeout (10s - 3600s)
	lockTimeout := v.cfg.Agents.Defaults.LockTimeoutSeconds
	if lockTimeout != 0 && (lockTimeout < 10 || lockTimeout > 3600) {
		result.Errors = append(result.Errors, ValidationError{
			Field:    "agents.defaults.lockTimeoutSeconds",
			Message:  fmt.Sprintf("invalid lock timeout: %ds (must be between 10 and 3600)", lockTimeout),
			Remedy:   "set a value between 10 and 3600, or 0 for default (120s)",
			Severity: SeverityCritical,
		})
	}
}

func (v *Validator) validateStrategic(result *ValidationResult) {
	// Validate Idempotency TTL
	v.validateTTL("strategic_edition.idempotencyTTL", v.cfg.Strategic.IdempotencyTTL, result)
}

func (v *Validator) validateTTL(field, value string, result *ValidationResult) {
	if value == "" {
		return
	}
	if _, err := time.ParseDuration(value); err != nil {
		result.Errors = append(result.Errors, ValidationError{
			Field:    field,
			Message:  fmt.Sprintf("invalid duration: %v", err),
			Remedy:   "use a valid Go duration string like '6h', '30m', or '1d'",
			Severity: SeverityCritical,
		})
	}
}

func (v *Validator) validateStorageRoot(result *ValidationResult) {
	root := v.cfg.StorageRoot()
	if root == "" {
		result.Errors = append(result.Errors, ValidationError{
			Field:    "strategic_edition.storage_root",
			Message:  "storage root is not configured",
			Remedy:   "run 'gobot init' to create default config",
			Severity: SeverityCritical,
		})
		return
	}

	info, err := os.Stat(root)
	if err != nil {
		if os.IsNotExist(err) {
			result.Errors = append(result.Errors, ValidationError{
				Field:    "strategic_edition.storage_root",
				Message:  fmt.Sprintf("directory does not exist: %s", root),
				Remedy:   "run 'gobot init' to create directories",
				Severity: SeverityCritical,
			})
		} else {
			result.Errors = append(result.Errors, ValidationError{
				Field:    "strategic_edition.storage_root",
				Message:  fmt.Sprintf("cannot access directory: %v", err),
				Remedy:   "check permissions on parent directory",
				Severity: SeverityCritical,
			})
		}
		return
	}

	if !info.IsDir() {
		result.Errors = append(result.Errors, ValidationError{
			Field:    "strategic_edition.storage_root",
			Message:  fmt.Sprintf("path is not a directory: %s", root),
			Remedy:   "remove the file and run 'gobot init'",
			Severity: SeverityCritical,
		})
		return
	}

	// Check writability by attempting to create a temporary file
	tmpFile, err := os.CreateTemp(root, ".gobot-write-test-*")
	if err != nil {
		result.Errors = append(result.Errors, ValidationError{
			Field:    "strategic_edition.storage_root",
			Message:  fmt.Sprintf("directory is not writable: %v", err),
			Remedy:   "check directory permissions",
			Severity: SeverityCritical,
		})
		return
	}
	_ = tmpFile.Close()
	_ = os.Remove(tmpFile.Name())
}

func (v *Validator) validateWorkspace(result *ValidationResult) {
	root := v.cfg.StorageRoot()
	if root == "" {
		return // Already reported in storage_root validation
	}

	workspace := filepath.Join(root, "workspace")
	if _, err := os.Stat(workspace); err != nil {
		if os.IsNotExist(err) {
			result.Errors = append(result.Errors, ValidationError{
				Field:    "workspace",
				Message:  fmt.Sprintf("workspace directory does not exist: %s", workspace),
				Remedy:   "run 'gobot init' to create workspace",
				Severity: SeverityWarning,
			})
		}
	}
}

func (v *Validator) validateAPIKeys(result *ValidationResult) {
	hasGemini := v.cfg.GeminiAPIKey() != ""
	hasAnthropic := v.cfg.AnthropicAPIKey() != ""
	hasOpenAI := v.cfg.OpenAIAPIKey() != ""
	hasOpenRouter := v.cfg.OpenRouterAPIKey() != ""

	if !hasGemini && !hasAnthropic && !hasOpenAI && !hasOpenRouter {
		result.Errors = append(result.Errors, ValidationError{
			Field:    "providers.api_key",
			Message:  "no API key configured for any provider",
			Remedy:   "set providers.gemini.apiKey, providers.anthropic.apiKey, providers.openai.apiKey, or providers.openrouter.apiKey in config",
			Severity: SeverityCritical,
		})
		return
	}

	v.validateProviderKeyFormat(result, "gemini", hasGemini, v.cfg.GeminiAPIKey(), func(key string) bool {
		return len(key) < 10
	})
	v.validateProviderKeyFormat(result, "anthropic", hasAnthropic, v.cfg.AnthropicAPIKey(), func(key string) bool {
		return !strings.HasPrefix(key, "sk-")
	})
	v.validateProviderKeyFormat(result, "openai", hasOpenAI, v.cfg.OpenAIAPIKey(), func(key string) bool {
		return !strings.HasPrefix(key, "sk-")
	})
	v.validateProviderKeyFormat(result, "openrouter", hasOpenRouter, v.cfg.OpenRouterAPIKey(), func(key string) bool {
		return !strings.HasPrefix(key, "sk-or-")
	})

	v.validateGoogleSearch(result)
}

func (v *Validator) validateProviderKeyFormat(result *ValidationResult, provider string, hasKey bool, key string, isInvalid func(string) bool) {
	if !hasKey {
		return
	}
	if isInvalid(key) {
		result.Errors = append(result.Errors, ValidationError{
			Field:    fmt.Sprintf("providers.%s.apiKey", provider),
			Message:  fmt.Sprintf("API key format appears invalid for %s", provider),
			Remedy:   fmt.Sprintf("check your %s API key", provider),
			Severity: SeverityCritical,
		})
	}
}

func (v *Validator) validateGoogleSearch(result *ValidationResult) {
	googleKey := v.cfg.GoogleAPIKey()
	googleCX := v.cfg.GoogleCX()

	if (googleKey != "" && googleCX == "") || (googleKey == "" && googleCX != "") {
		result.Errors = append(result.Errors, ValidationError{
			Field:    "providers.google",
			Message:  "both apiKey and customCx must be provided for Google Search",
			Remedy:   "ensure both providers.google.apiKey and providers.google.customCx are set",
			Severity: SeverityWarning,
		})
	}
}

func (v *Validator) validateTelegram(result *ValidationResult) {
	if !v.cfg.Channels.Telegram.Enabled {
		return // Telegram disabled, skip validation
	}

	token := v.cfg.TelegramToken()
	if token == "" {
		result.Errors = append(result.Errors, ValidationError{
			Field:    "channels.telegram.token",
			Message:  "telegram is enabled but no token is configured",
			Remedy:   "set channels.telegram.token or TELEGRAM_BOT_TOKEN env var",
			Severity: SeverityCritical,
		})
		return
	}

	// Basic bot token format validation: should contain a colon
	if !strings.Contains(token, ":") {
		result.Errors = append(result.Errors, ValidationError{
			Field:    "channels.telegram.token",
			Message:  "token format appears invalid (should contain ':')",
			Remedy:   "check your Telegram bot token from @BotFather",
			Severity: SeverityCritical,
		})
	}

	// Validate allowFrom entries
	if len(v.cfg.Channels.Telegram.AllowFrom) == 0 {
		result.Errors = append(result.Errors, ValidationError{
			Field:    "channels.telegram.allowFrom",
			Message:  "no authorized chat IDs configured",
			Remedy:   "add your Telegram chat ID to channels.telegram.allowFrom",
			Severity: SeverityCritical,
		})
	}
}

func (v *Validator) validatePaths(result *ValidationResult) {
	root := v.cfg.StorageRoot()
	if root == "" {
		return
	}

	// Check for AWARENESS.md in workspace
	awarenessPath := filepath.Join(root, "workspace", "AWARENESS.md")
	if _, err := os.Stat(awarenessPath); err != nil {
		if os.IsNotExist(err) {
			result.Errors = append(result.Errors, ValidationError{
				Field:    "awareness_file",
				Message:  fmt.Sprintf("AWARENESS.md not found: %s", awarenessPath),
				Remedy:   "create AWARENESS.md in workspace or run 'gobot init'",
				Severity: SeverityWarning,
			})
		}
	}

	// Check secrets directory permissions (platform-specific)
	secretsDir := filepath.Join(root, "secrets")
	if err := v.checkPathPermissions(secretsDir, result); err != nil {
		slog.Debug("path permission check failed", "path", secretsDir, "err", err)
	}
}

func (v *Validator) validateDiskSpace(result *ValidationResult) {
	root := v.cfg.StorageRoot()
	if root == "" {
		return
	}

	// Get available disk space (platform-specific)
	if err := v.checkDiskSpace(root, result); err != nil {
		slog.Debug("disk space check failed", "path", root, "err", err)
	}
}

// ReportValidation validates config and logs results.
// Returns an error if critical errors exist, nil otherwise.
func ReportValidation(cfg *Config) error {
	validator := NewValidator(cfg)
	result := validator.Validate()

	if !result.HasErrors() {
		return nil
	}

	for _, e := range result.Errors {
		if e.Severity == SeverityCritical {
			slog.Error("configuration error", "field", e.Field, "msg", e.Message, "remedy", e.Remedy)
		} else {
			slog.Warn("configuration warning", "field", e.Field, "msg", e.Message, "remedy", e.Remedy)
		}
	}

	if result.HasCritical() {
		return errors.New("configuration validation failed with critical errors")
	}

	return nil
}
