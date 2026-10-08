//nolint:testpackage // requires unexported validator internals for testing
package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// helper to create a base valid config for testing.
func baseValidConfig(t *testing.T) *Config {
	t.Helper()
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
		Runtime: RuntimeConfig{
			StorageRoot: tmpDir,
		},
		Providers: ProvidersConfig{
			Gemini: GeminiConfig{APIKey: "AIzaSyA_valid_key_here"}, // nolint:gosec // test key
		},
	}
}

func assertFieldError(t *testing.T, result *ValidationResult, errorField string, wantError bool) {
	t.Helper()
	hasError := false
	for _, e := range result.Errors {
		if e.Field == errorField {
			hasError = true
			break
		}
	}

	if wantError && !hasError {
		t.Errorf("expected error for field %s, got none. Errors: %v", errorField, result.Errors)
	}
	if !wantError && hasError {
		t.Errorf("expected no errors, got error for field %s", errorField)
	}
}

func cleanEnv(t *testing.T) {
	t.Helper()
	// Isolate test from environment variables that could affect validation
	vars := []string{
		"GEMINI_API_KEY",
		"ANTHROPIC_API_KEY",
		"OPENAI_API_KEY",
		"OPENAI_BASE_URL",
		"OPENROUTER_API_KEY",
		"OPENROUTER_BASE_URL",
		"GOOGLE_API_KEY",
		"GOOGLE_CX",
		"TELEGRAM_BOT_TOKEN",
	}
	for _, v := range vars {
		orig := os.Getenv(v)
		t.Cleanup(func() { os.Setenv(v, orig) })
		os.Unsetenv(v)
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
			errorField:  "runtime.storage_root",
		},
		{
			name:        "non-existent storage root",
			storageRoot: "/nonexistent/path/that/does/not/exist",
			wantError:   true,
			errorField:  "runtime.storage_root",
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			cfg := baseValidConfig(t)
			cfg.Runtime.StorageRoot = tt.storageRoot

			validator := NewValidator(cfg)
			result := validator.Validate()

			if tt.wantError && tt.storageRoot == "" && cfg.StorageRoot() != "" {
				t.Logf("Skipping empty storage root test because fallback returned %s", cfg.StorageRoot())
				return
			}
			assertFieldError(t, result, tt.errorField, tt.wantError)
		})
	}
}

func TestValidator_Validate_APIKeys(t *testing.T) {
	t.Parallel()
	for _, tt := range getAPIKeyTestCases() {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			cleanEnv(t)

			cfg := baseValidConfig(t)
			cfg.Providers = ProvidersConfig{
				Gemini:     GeminiConfig{APIKey: tt.geminiKey},
				Anthropic:  AnthropicConfig{APIKey: tt.anthropicKey},
				OpenAI:     OpenAIConfig{APIKey: tt.openAIKey},
				OpenRouter: OpenAIConfig{APIKey: tt.openRouterKey},
			}

			validator := NewValidator(cfg)
			result := validator.Validate()

			assertFieldError(t, result, tt.errorField, tt.wantError)
		})
	}
}

type apiKeyTestCase struct {
	name          string
	geminiKey     string
	anthropicKey  string
	openAIKey     string
	openRouterKey string
	wantError     bool
	errorField    string
}

func getAPIKeyTestCases() []apiKeyTestCase {
	return []apiKeyTestCase{
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
		{
			name:          "valid OpenRouter key",
			openRouterKey: "sk-or-v1-valid-key",
			wantError:     false,
		},
		{
			name:          "invalid OpenRouter key format",
			openRouterKey: "not-starting-with-sk-or-",
			wantError:     true,
			errorField:    "providers.openrouter.apiKey",
		},
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

			assertFieldError(t, result, tt.errorField, tt.wantError)
		})
	}
}

func TestValidator_Validate_AgentDefaults(t *testing.T) {
	t.Parallel()
	for _, tt := range getAgentDefaultsTestCases() {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			cfg := baseValidConfig(t)
			applyAgentDefaults(cfg, tt)

			validator := NewValidator(cfg)
			result := validator.Validate()

			assertFieldError(t, result, tt.errorField, tt.wantError)
		})
	}
}

type agentDefaultsTestCase struct {
	name           string
	lockTimeout    int
	pruningTTL     string
	compactionTTL  string
	idempotencyTTL string
	wantError      bool
	errorField     string
}

func getAgentDefaultsTestCases() []agentDefaultsTestCase {
	return []agentDefaultsTestCase{
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
			errorField:     "runtime.idempotencyTTL",
		},
		{
			name:           "valid idempotency ttl",
			idempotencyTTL: "24h",
			wantError:      false,
		},
	}
}

func applyAgentDefaults(cfg *Config, tt agentDefaultsTestCase) {
	cfg.Agents.Defaults.LockTimeoutSeconds = tt.lockTimeout
	cfg.Agents.Defaults.ContextPruning.TTL = tt.pruningTTL
	cfg.Agents.Defaults.Compaction.MemoryFlush.TTL = tt.compactionTTL
	cfg.Runtime.IdempotencyTTL = tt.idempotencyTTL
}

func TestValidationResult_CriticalErrors(t *testing.T) {
	t.Parallel()
	result := &ValidationResult{
		Errors: []ValidationError{
			{Field: "runtime.storage_root", Message: "not found", Severity: SeverityCritical},
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
	// Isolate test from environment variables that could affect validation
	origGemini := os.Getenv("GEMINI_API_KEY")
	origAnthropic := os.Getenv("ANTHROPIC_API_KEY")
	origOpenAI := os.Getenv("OPENAI_API_KEY")
	origOpenAIBaseURL := os.Getenv("OPENAI_BASE_URL")
	origGoogleKey := os.Getenv("GOOGLE_API_KEY")
	origGoogleCX := os.Getenv("GOOGLE_CX")
	origTelegram := os.Getenv("TELEGRAM_BOT_TOKEN")
	defer func() {
		os.Setenv("GEMINI_API_KEY", origGemini)
		os.Setenv("ANTHROPIC_API_KEY", origAnthropic)
		os.Setenv("OPENAI_API_KEY", origOpenAI)
		os.Setenv("OPENAI_BASE_URL", origOpenAIBaseURL)
		os.Setenv("GOOGLE_API_KEY", origGoogleKey)
		os.Setenv("GOOGLE_CX", origGoogleCX)
		os.Setenv("TELEGRAM_BOT_TOKEN", origTelegram)
	}()
	// Unset all relevant environment variables for clean test
	os.Unsetenv("GEMINI_API_KEY")
	os.Unsetenv("ANTHROPIC_API_KEY")
	os.Unsetenv("OPENAI_API_KEY")
	os.Unsetenv("OPENAI_BASE_URL")
	os.Unsetenv("GOOGLE_API_KEY")
	os.Unsetenv("GOOGLE_CX")
	os.Unsetenv("TELEGRAM_BOT_TOKEN")

	// Valid config should return nil
	validCfg := baseValidConfig(t)

	if err := ReportValidation(validCfg); err != nil {
		t.Errorf("expected nil for valid config, got: %v", err)
	}

	// Invalid config with critical error should return error
	invalidCfg := baseValidConfig(t)
	invalidCfg.Runtime.StorageRoot = ""

	// Special case for Windows fallback again
	if invalidCfg.StorageRoot() != "" {
		t.Log("Skipping empty storage root test in ReportValidation due to fallback")
		return
	}

	if err := ReportValidation(invalidCfg); err == nil {
		t.Error("expected error for invalid config, got nil")
	}
}

func TestValidationError_Actionable(t *testing.T) {
	t.Parallel()
	e := ValidationError{
		Field:    "channels.telegram.token",
		Message:  "telegram is enabled but no token is configured",
		Remedy:   "set channels.telegram.token or TELEGRAM_BOT_TOKEN env var",
		Severity: SeverityCritical,
	}
	got := e.Actionable()
	if !strings.Contains(got, "Problem: telegram is enabled but no token is configured") {
		t.Errorf("missing problem line: %q", got)
	}
	if !strings.Contains(got, "Fix:   set channels.telegram.token") {
		t.Errorf("missing fix line: %q", got)
	}
	if !strings.Contains(got, "Path:  channels.telegram.token") {
		t.Errorf("missing path line: %q", got)
	}
}

func TestValidationError_Actionable_FallbackFix(t *testing.T) {
	t.Parallel()
	e := ValidationError{Field: "f", Message: "m"}
	if !strings.Contains(e.Actionable(), "Fix:   see docs/configuration.md") {
		t.Errorf("expected fallback fix, got %q", e.Actionable())
	}
}

func TestValidationResult_FormatActionable_CriticalFirst(t *testing.T) {
	t.Parallel()
	r := &ValidationResult{Errors: []ValidationError{
		{Field: "warn.field", Message: "a warning", Remedy: "fix warn", Severity: SeverityWarning},
		{Field: "crit.field", Message: "a critical", Remedy: "fix crit", Severity: SeverityCritical},
	}}
	out := r.FormatActionable()
	ci := strings.Index(out, "a critical")
	wi := strings.Index(out, "a warning")
	if ci == -1 || wi == -1 {
		t.Fatalf("both errors should render: %q", out)
	}
	if ci > wi {
		t.Errorf("critical must render before warning: %q", out)
	}
}

func TestValidationResult_FormatActionable_Empty(t *testing.T) {
	t.Parallel()
	if got := (&ValidationResult{}).FormatActionable(); got != "" {
		t.Errorf("expected empty string for no errors, got %q", got)
	}
}

func TestParseTelegramChatID(t *testing.T) {
	t.Parallel()
	for _, tt := range []struct {
		raw     string
		want    int64
		invalid bool
	}{
		{"", 0, true}, {"abc", 0, true}, {" 123", 0, true}, {"123 ", 0, true},
		{"0", 0, true}, {"+0", 0, true}, {"-0", 0, true}, {"0x10", 0, true},
		{"1.5", 0, true}, {"*", 0, true}, {"@user", 0, true},
		{"9223372036854775808", 0, true}, {"-9223372036854775809", 0, true},
		{"123", 123, false}, {"-100123", -100123, false}, {"+123", 123, false},
		{"00123", 123, false}, {"9223372036854775807", 9223372036854775807, false},
		{"-9223372036854775808", -9223372036854775808, false},
	} {
		t.Run(tt.raw, func(t *testing.T) {
			t.Parallel()
			got, err := ParseTelegramChatID(tt.raw)
			if (err != nil) != tt.invalid || got != tt.want {
				t.Fatalf("parse %q = %d, %v; want %d invalid=%t", tt.raw, got, err, tt.want, tt.invalid)
			}
		})
	}
}

//nolint:paralleltest // token environment isolation.
func TestTelegramWhitelistValidation(t *testing.T) {
	t.Setenv("TELEGRAM_BOT_TOKEN", "")
	for _, tt := range []struct {
		name    string
		ids     []string
		invalid bool
	}{
		{"nil", nil, true}, {"empty", []string{}, true}, {"blank", []string{""}, true},
		{"all invalid", []string{"abc", "0"}, true}, {"mixed", []string{"123", "abc"}, true},
		{"whitespace", []string{" 123"}, true}, {"signed zero", []string{"+0", "-0"}, true},
		{"overflow", []string{"9223372036854775808", "-9223372036854775809"}, true},
		{"valid", []string{"123"}, false}, {"signed groups", []string{"-100123", "+123", "00123"}, false},
		{"duplicates", []string{"123", "123"}, false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			for _, enabled := range []bool{false, true} {
				for _, token := range []string{"", "123:token"} {
					cfg := &Config{}
					cfg.Channels.Telegram.Enabled = enabled
					cfg.Channels.Telegram.Token = token
					cfg.Channels.Telegram.AllowFrom = tt.ids
					result := &ValidationResult{}
					NewValidator(cfg).validateTelegram(result)
					assertTelegramWhitelistDiagnostics(t, result, enabled && tt.invalid)
				}
			}
		})
	}
}

func assertTelegramWhitelistDiagnostics(t *testing.T, result *ValidationResult, want bool) {
	t.Helper()
	found := false
	for _, e := range result.Errors {
		if strings.HasPrefix(e.Field, "channels.telegram.allowFrom") {
			found = true
			if e.Severity != SeverityCritical || !strings.Contains(e.Remedy, "nonzero signed decimal") {
				t.Fatalf("non-actionable whitelist diagnostic: %+v", e)
			}
		}
	}
	if found != want {
		t.Fatalf("whitelist error=%t want=%t errors=%v", found, want, result.Errors)
	}
}
