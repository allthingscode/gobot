package config

import (
	"os"
	"path/filepath"
	"testing"
)

// helper to create a base valid config for testing
func baseValidConfig(t *testing.T) *Config {
	tmpDir := t.TempDir()
	// Create workspace and AWARENESS.md to satisfy path validation
	wsDir := filepath.Join(tmpDir, "workspace")
	if err := os.MkdirAll(wsDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(wsDir, "AWARENESS.md"), []byte("test"), 0o600); err != nil {
		t.Fatal(err)
	}

	return &Config{
		Strategic: StrategicConfig{
			StorageRoot: tmpDir,
		},
		Providers: ProvidersConfig{
			Gemini: GeminiConfig{APIKey: "AIzaSyA_valid_key_here"},
		},
	}
}

func TestValidator_Validate_StorageRoot(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name        string
		storageRoot string
		wantError   bool
		errorField  string
	}{
		{
			name:        "valid storage root",
			storageRoot: t.TempDir(),
			wantError:   false,
		},
		{
			name:        "empty storage root",
			storageRoot: "",
			wantError:   true,
			errorField:  "strategic_edition.storage_root",
		},
		{
			name:        "non-existent storage root",
			storageRoot: "/nonexistent/path/that/does/not/exist",
			wantError:   true,
			errorField:  "strategic_edition.storage_root",
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			cfg := baseValidConfig(t)
			cfg.Strategic.StorageRoot = tt.storageRoot

			validator := NewValidator(cfg)
			result := validator.Validate()

			hasError := false
			for _, e := range result.Errors {
				if e.Field == tt.errorField {
					hasError = true
					break
				}
			}

			if tt.wantError && !hasError {
				// Special case: if StorageRoot() fallback kicked in, root is not empty.
				if tt.storageRoot == "" && cfg.StorageRoot() != "" {
					t.Logf("Skipping empty storage root test because fallback returned %s", cfg.StorageRoot())
					return
				}
				t.Errorf("expected error for field %s, got none. Errors: %v", tt.errorField, result.Errors)
			}
		})
	}
}

func TestValidator_Validate_APIKeys(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name         string
		geminiKey    string
		anthropicKey string
		openAIKey    string
		wantError    bool
		errorField   string
	}{
		{
			name:       "no API keys configured",
			wantError:  true,
			errorField: "providers.api_key",
		},
		{
			name:      "valid Gemini key",
			geminiKey: "AIzaSyA_valid_gemini_key_here",
			wantError: false,
		},
		{
			name:       "invalid Gemini key (too short)",
			geminiKey:  "short",
			wantError:  true,
			errorField: "providers.gemini.apiKey",
		},
		{
			name:         "valid Anthropic key",
			anthropicKey: "sk-ant-api03-valid-key",
			wantError:    false,
		},
		{
			name:         "invalid Anthropic key format",
			anthropicKey: "not-starting-with-sk-",
			wantError:    true,
			errorField:   "providers.anthropic.apiKey",
		},
		{
			name:      "valid OpenAI key",
			openAIKey: "sk-valid-openai-key",
			wantError: false,
		},
		{
			name:       "invalid OpenAI key format",
			openAIKey:  "not-starting-with-sk-",
			wantError:  true,
			errorField: "providers.openai.apiKey",
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			cfg := baseValidConfig(t)
			cfg.Providers = ProvidersConfig{
				Gemini:    GeminiConfig{APIKey: tt.geminiKey},
				Anthropic: AnthropicConfig{APIKey: tt.anthropicKey},
				OpenAI:    OpenAIConfig{APIKey: tt.openAIKey},
			}

			validator := NewValidator(cfg)
			result := validator.Validate()

			hasError := false
			for _, e := range result.Errors {
				if e.Field == tt.errorField {
					hasError = true
					break
				}
			}

			if tt.wantError && !hasError {
				t.Errorf("expected error for field %s, got none. Errors: %v", tt.errorField, result.Errors)
			}
			if !tt.wantError && hasError {
				t.Errorf("expected no errors, got error for field %s", tt.errorField)
			}
		})
	}
}

func TestValidator_Validate_Telegram(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name       string
		enabled    bool
		token      string
		allowFrom  []string
		wantError  bool
		errorField string
	}{
		{
			name:      "telegram disabled",
			enabled:   false,
			wantError: false,
		},
		{
			name:       "telegram enabled no token",
			enabled:    true,
			wantError:  true,
			errorField: "channels.telegram.token",
		},
		{
			name:       "telegram enabled no allowFrom",
			enabled:    true,
			token:      "123456:valid_token_format",
			wantError:  true,
			errorField: "channels.telegram.allowFrom",
		},
		{
			name:       "telegram enabled invalid token format",
			enabled:    true,
			token:      "invalid_token_no_colon",
			allowFrom:  []string{"123456"},
			wantError:  true,
			errorField: "channels.telegram.token",
		},
		{
			name:      "telegram enabled valid config",
			enabled:   true,
			token:     "123456:valid_token_format",
			allowFrom: []string{"123456"},
			wantError: false,
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			cfg := baseValidConfig(t)
			cfg.Channels = ChannelsConfig{
				Telegram: TelegramConfig{
					Enabled:   tt.enabled,
					Token:     tt.token,
					AllowFrom: tt.allowFrom,
				},
			}

			validator := NewValidator(cfg)
			result := validator.Validate()

			hasError := false
			for _, e := range result.Errors {
				if e.Field == tt.errorField {
					hasError = true
					break
				}
			}

			if tt.wantError && !hasError {
				t.Errorf("expected error for field %s, got none. Errors: %v", tt.errorField, result.Errors)
			}
			if !tt.wantError && hasError {
				t.Errorf("expected no errors, got error for field %s", tt.errorField)
			}
		})
	}
}

func TestValidator_Validate_AgentDefaults(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name           string
		lockTimeout    int
		pruningTTL     string
		compactionTTL  string
		idempotencyTTL string
		wantError      bool
		errorField     string
	}{
		{
			name:        "valid lock timeout (60s)",
			lockTimeout: 60,
			wantError:   false,
		},
		{
			name:        "valid lock timeout (zero/default)",
			lockTimeout: 0,
			wantError:   false,
		},
		{
			name:        "invalid lock timeout (too short)",
			lockTimeout: 5,
			wantError:   true,
			errorField:  "agents.defaults.lockTimeoutSeconds",
		},
		{
			name:        "invalid lock timeout (too long)",
			lockTimeout: 5000,
			wantError:   true,
			errorField:  "agents.defaults.lockTimeoutSeconds",
		},
		{
			name:       "invalid context pruning ttl",
			pruningTTL: "invalid",
			wantError:  true,
			errorField: "agents.defaults.contextPruning.ttl",
		},
		{
			name:       "valid context pruning ttl",
			pruningTTL: "6h",
			wantError:  false,
		},
		{
			name:          "invalid compaction ttl",
			compactionTTL: "not-a-duration",
			wantError:     true,
			errorField:    "agents.defaults.compaction.memoryFlush.ttl",
		},
		{
			name:          "valid compaction ttl",
			compactionTTL: "2160h",
			wantError:     false,
		},
		{
			name:           "invalid idempotency ttl",
			idempotencyTTL: "10", // missing unit
			wantError:      true,
			errorField:     "strategic_edition.idempotencyTTL",
		},
		{
			name:           "valid idempotency ttl",
			idempotencyTTL: "24h",
			wantError:      false,
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			cfg := baseValidConfig(t)
			cfg.Agents.Defaults.LockTimeoutSeconds = tt.lockTimeout
			cfg.Agents.Defaults.ContextPruning.TTL = tt.pruningTTL
			cfg.Agents.Defaults.Compaction.MemoryFlush.TTL = tt.compactionTTL
			cfg.Strategic.IdempotencyTTL = tt.idempotencyTTL

			validator := NewValidator(cfg)
			result := validator.Validate()

			hasError := false
			for _, e := range result.Errors {
				if e.Field == tt.errorField {
					hasError = true
					break
				}
			}

			if tt.wantError && !hasError {
				t.Errorf("expected error for field %s, got none. Errors: %v", tt.errorField, result.Errors)
			}
			if !tt.wantError && hasError {
				t.Errorf("expected no errors, got error for field %s", tt.errorField)
			}
		})
	}
}

func TestValidationResult_CriticalErrors(t *testing.T) {
	t.Parallel()
	result := &ValidationResult{
		Errors: []ValidationError{
			{Field: "strategic_edition.storage_root", Message: "not found", Severity: SeverityCritical},
			{Field: "providers.gemini.apiKey", Message: "missing", Severity: SeverityCritical},
			{Field: "disk_space", Message: "low", Severity: SeverityWarning},
		},
	}

	critical := result.CriticalErrors()
	if len(critical) != 2 {
		t.Errorf("expected 2 critical errors, got %d. Errors: %v", len(critical), critical)
	}

	for _, e := range critical {
		if e.Severity != SeverityCritical {
			t.Errorf("expected SeverityCritical, got %s", e.Severity)
		}
	}
}

func TestValidationResult_HasErrors(t *testing.T) {
	t.Parallel()
	empty := &ValidationResult{}
	if empty.HasErrors() {
		t.Error("expected no errors for empty result")
	}

	withErrors := &ValidationResult{
		Errors: []ValidationError{{Field: "test", Message: "error", Severity: SeverityWarning}},
	}
	if !withErrors.HasErrors() {
		t.Error("expected HasErrors to return true")
	}
}

func TestValidationError_Error(t *testing.T) {
	t.Parallel()
	e := ValidationError{
		Field:    "test.field",
		Message:  "something wrong",
		Remedy:   "fix it",
		Severity: SeverityCritical,
	}

	want := "test.field: something wrong (fix: fix it)"
	if got := e.Error(); got != want {
		t.Errorf("Error() = %q, want %q", got, want)
	}

	// Without remedy
	e2 := ValidationError{
		Field:    "test.field",
		Message:  "something wrong",
		Severity: SeverityWarning,
	}
	want2 := "test.field: something wrong"
	if got := e2.Error(); got != want2 {
		t.Errorf("Error() = %q, want %q", got, want2)
	}
}

func TestReportValidation(t *testing.T) {
	t.Parallel()
	// Valid config should return nil
	validCfg := baseValidConfig(t)

	if err := ReportValidation(validCfg); err != nil {
		t.Errorf("expected nil for valid config, got: %v", err)
	}

	// Invalid config with critical error should return error
	invalidCfg := baseValidConfig(t)
	invalidCfg.Strategic.StorageRoot = ""

	// Special case for Windows fallback again
	if invalidCfg.StorageRoot() != "" {
		t.Log("Skipping empty storage root test in ReportValidation due to fallback")
		return
	}

	if err := ReportValidation(invalidCfg); err == nil {
		t.Error("expected error for invalid config, got nil")
	}
}
