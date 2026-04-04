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

	return result
}

func (v *Validator) validateAgentDefaults(result *ValidationResult) {
	// Validate Context Pruning TTL
	ttl := v.cfg.Agents.Defaults.ContextPruning.TTL
	if ttl != "" {
		if _, err := time.ParseDuration(ttl); err != nil {
			result.Errors = append(result.Errors, ValidationError{
				Field:    "agents.defaults.contextPruning.ttl",
				Message:  fmt.Sprintf("invalid duration: %v", err),
				Remedy:   "use a valid Go duration string like '6h', '30m', or '1d'",
				Severity: SeverityCritical,
			})
		}
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
	tmpFile.Close()
	os.Remove(tmpFile.Name())
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
	// Check at least one provider has an API key
	hasGemini := v.cfg.GeminiAPIKey() != ""
	hasAnthropic := v.cfg.AnthropicAPIKey() != ""
	hasOpenAI := v.cfg.OpenAIAPIKey() != ""

	if !hasGemini && !hasAnthropic && !hasOpenAI {
		result.Errors = append(result.Errors, ValidationError{
			Field:    "providers.api_key",
			Message:  "no API key configured for any provider",
			Remedy:   "set providers.gemini.apiKey, providers.anthropic.apiKey, or providers.openai.apiKey in config",
			Severity: SeverityCritical,
		})
		return
	}

	// Validate key format (basic length check)
	if hasGemini {
		key := v.cfg.GeminiAPIKey()
		if len(key) < 10 {
			result.Errors = append(result.Errors, ValidationError{
				Field:    "providers.gemini.apiKey",
				Message:  "API key appears invalid (too short)",
				Remedy:   "check your Gemini API key",
				Severity: SeverityCritical,
			})
		}
	}

	if hasAnthropic {
		key := v.cfg.AnthropicAPIKey()
		if !strings.HasPrefix(key, "sk-") {
			result.Errors = append(result.Errors, ValidationError{
				Field:    "providers.anthropic.apiKey",
				Message:  "API key format appears invalid (should start with 'sk-')",
				Remedy:   "check your Anthropic API key",
				Severity: SeverityCritical,
			})
		}
	}

	if hasOpenAI {
		key := v.cfg.OpenAIAPIKey()
		if !strings.HasPrefix(key, "sk-") {
			result.Errors = append(result.Errors, ValidationError{
				Field:    "providers.openai.apiKey",
				Message:  "API key format appears invalid (should start with 'sk-')",
				Remedy:   "check your OpenAI API key",
				Severity: SeverityCritical,
			})
		}
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
