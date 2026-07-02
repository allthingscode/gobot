//nolint:testpackage // covers package-private accessors and defaults
package config

import (
	"log/slog"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

//nolint:cyclop,funlen,gocognit // Broad accessor coverage intentionally keeps default/configured assertions together.
func TestAccessorDefaultsAndConfiguredValues(t *testing.T) {
	t.Parallel()

	var cfg Config
	if (SummarizationConfig{}).IsSummarizationEnabled() {
		t.Fatal("zero summarization should be disabled")
	}
	if got := (SummarizationConfig{}).SummarizationThreshold(); got != DefaultSummarizationThreshold {
		t.Fatalf("default summarization threshold = %v", got)
	}
	if got := (SummarizationConfig{Threshold: 0.5}).SummarizationThreshold(); got != 0.5 {
		t.Fatalf("configured summarization threshold = %v", got)
	}
	if got := (SummarizationConfig{}).SummarizationModel("default-model"); got != "default-model" {
		t.Fatalf("default summarization model = %q", got)
	}
	if got := (SummarizationConfig{Enabled: true, Model: "summary-model"}).SummarizationModel("default-model"); got != "summary-model" {
		t.Fatalf("configured summarization model = %q", got)
	}

	if cfg.VectorSearchEnabled() {
		t.Fatal("zero config vector search should be disabled")
	}
	cfg.Runtime.VectorSearchEnabled = true
	if !cfg.VectorSearchEnabled() {
		t.Fatal("configured vector search should be enabled")
	}

	if got := cfg.GoogleScopes(); len(got) != 3 {
		t.Fatalf("default scopes = %v", got)
	}
	cfg.Runtime.GoogleScopes = []string{"scope-a"}
	if got := cfg.GoogleScopes(); !reflect.DeepEqual(got, []string{"scope-a"}) {
		t.Fatalf("configured scopes = %v", got)
	}

	if got := (&Config{}).MemoryWindow(); got != 50 {
		t.Fatalf("default memory window = %d", got)
	}
	cfg.Agents.Defaults.MemoryWindow = 12
	if got := cfg.MemoryWindow(); got != 12 {
		t.Fatalf("configured memory window = %d", got)
	}

	cfg.Agents.Defaults.ContextPruning = ContextPruningConfig{TTL: "1h", KeepLastAssistants: 2}
	if got := cfg.ContextPruning(); got.TTL != "1h" || got.KeepLastAssistants != 2 {
		t.Fatalf("context pruning = %#v", got)
	}
	cfg.Agents.Defaults.Compaction = CompactionPolicyConfig{Strategy: "summarize"}
	if got := cfg.Compaction(); got.Strategy != "summarize" {
		t.Fatalf("compaction = %#v", got)
	}

	if got := (&Config{}).SessionTokenBudget(); got != 80000 {
		t.Fatalf("default session token budget = %d", got)
	}
	cfg.Context.SessionTokenBudget = 42
	if got := cfg.SessionTokenBudget(); got != 42 {
		t.Fatalf("configured session token budget = %d", got)
	}
	if got := (&Config{}).CompactionSummaryTurns(); got != 20 {
		t.Fatalf("default summary turns = %d", got)
	}
	cfg.Context.CompactionSummaryTurns = 7
	if got := cfg.CompactionSummaryTurns(); got != 7 {
		t.Fatalf("configured summary turns = %d", got)
	}

	if got := (&Config{}).EffectiveIdempotencyTTL(); got != 24*time.Hour {
		t.Fatalf("default idempotency ttl = %s", got)
	}
	cfg.Runtime.IdempotencyTTL = "2h"
	if got := cfg.EffectiveIdempotencyTTL(); got != 2*time.Hour {
		t.Fatalf("configured idempotency ttl = %s", got)
	}
	cfg.Runtime.IdempotencyTTL = "bad"
	if got := cfg.EffectiveIdempotencyTTL(); got != 24*time.Hour {
		t.Fatalf("invalid idempotency ttl = %s", got)
	}

	if got := (&Config{}).MaxTokens(); got != 0 {
		t.Fatalf("default max tokens = %d", got)
	}
	cfg.Agents.Defaults.MaxTokens = 123
	if got := cfg.MaxTokens(); got != 123 {
		t.Fatalf("configured max tokens = %d", got)
	}
}

//nolint:cyclop,funlen,gocognit // Broad accessor coverage intentionally keeps provider/risk assertions together.
func TestProviderTelemetryPathAndRiskAccessors(t *testing.T) {
	t.Parallel()

	const (
		autoProvider   = "auto"
		geminiProvider = "gemini"
		openAIProvider = "openai"
		otlpEndpoint   = "localhost:4317"
	)

	cfg := &Config{}
	if got := cfg.DefaultProvider(); got != geminiProvider {
		t.Fatalf("default provider = %q", got)
	}
	cfg.Agents.Defaults.Provider = autoProvider
	if got := cfg.DefaultProvider(); got != geminiProvider {
		t.Fatalf("auto provider = %q", got)
	}
	cfg.Agents.Defaults.Provider = openAIProvider
	if got := cfg.DefaultProvider(); got != openAIProvider {
		t.Fatalf("configured provider = %q", got)
	}
	cfg.Agents.Specialists = map[string]SpecialistConfig{
		"researcher": {Provider: "anthropic"},
		"architect":  {Provider: autoProvider},
	}
	if got := cfg.SpecialistProvider("researcher"); got != "anthropic" {
		t.Fatalf("specialist provider = %q", got)
	}
	if got := cfg.SpecialistProvider("architect"); got != openAIProvider {
		t.Fatalf("auto specialist provider = %q", got)
	}

	if got := (&Config{}).HeartbeatInterval(); got != 15*time.Minute {
		t.Fatalf("default heartbeat interval = %s", got)
	}
	cfg.Heartbeat.Interval = "30s"
	if got := cfg.HeartbeatInterval(); got != 30*time.Second {
		t.Fatalf("configured heartbeat interval = %s", got)
	}
	cfg.Heartbeat.Interval = "bad"
	if got := cfg.HeartbeatInterval(); got != 15*time.Minute {
		t.Fatalf("invalid heartbeat interval = %s", got)
	}

	if cfg.TelemetryEnabled() {
		t.Fatal("telemetry should be disabled without endpoint")
	}
	cfg.Runtime.Observability.OTLPEndpoint = otlpEndpoint
	if !cfg.TelemetryEnabled() || cfg.OTelEndpoint() != otlpEndpoint {
		t.Fatalf("telemetry endpoint not surfaced: enabled=%v endpoint=%q", cfg.TelemetryEnabled(), cfg.OTelEndpoint())
	}

	cfg.Tools.HighRisk = []string{"shell_exec"}
	if got := cfg.HighRiskTools(); !reflect.DeepEqual(got, []string{"shell_exec"}) {
		t.Fatalf("high risk tools = %v", got)
	}

	cfg.SetProjectRoot(filepath.Join("tmp", "project"))
	if cfg.ProjectRoot() == "" {
		t.Fatal("project root should be set")
	}
	cfg.Runtime.TemplatesPath = "custom-templates"
	if got := cfg.TemplatesPath(); got != "custom-templates" {
		t.Fatalf("templates path = %q", got)
	}
	cfg.Runtime.PolicyFilePath = "policy.yaml"
	if got := cfg.PolicyFilePath(); got != "policy.yaml" {
		t.Fatalf("policy path = %q", got)
	}

	cfg.Providers.OpenRouter.BaseURL = "https://router.test"
	if got := cfg.OpenRouterBaseURL(); got != "https://router.test" {
		t.Fatalf("openrouter base URL = %q", got)
	}
	cfg.Channels.Telegram.AllowFrom = []string{"123"}
	if got := cfg.TelegramAllowedFrom(); !reflect.DeepEqual(got, []string{"123"}) {
		t.Fatalf("telegram allow from = %v", got)
	}

	for level, want := range map[string]slog.Level{
		"DEBUG": slog.LevelDebug,
		"WARN":  slog.LevelWarn,
		"ERROR": slog.LevelError,
		"INFO":  slog.LevelInfo,
	} {
		cfg.Logging.Level = level
		if got := cfg.LogLevel(); got != want {
			t.Fatalf("LogLevel(%q)=%v want=%v", level, got, want)
		}
	}
}
