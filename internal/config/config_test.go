package config

import (
	"bytes"
	"errors"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type errReader struct{}

func (errReader) Read(_ []byte) (int, error) { return 0, errors.New("read error") }

func TestDecode_NoBOM(t *testing.T) {
	input := `{"agents":{"defaults":{"model":"gemini-3-flash-preview"}}}`
	cfg, err := decode(bytes.NewReader([]byte(input)))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Agents.Defaults.Model != "gemini-3-flash-preview" {
		t.Errorf("got model %q, want %q", cfg.Agents.Defaults.Model, "gemini-3-flash-preview")
	}
}

func TestDecode_WithBOM(t *testing.T) {
	bom := []byte{0xEF, 0xBB, 0xBF}
	json := []byte(`{"providers":{"gemini":{"apiKey":"test-key"}}}`)
	input := append(bom, json...) //nolint:gocritic // intentional: prepend BOM to original json bytes

	cfg, err := decode(bytes.NewReader(input))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Providers.Gemini.APIKey != "test-key" {
		t.Errorf("got apiKey %q, want %q", cfg.Providers.Gemini.APIKey, "test-key")
	}
}

func TestDecode_MissingField_DoesNotError(t *testing.T) {
	cfg, err := decode(bytes.NewReader([]byte(`{}`)))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Agents.Defaults.Model != "" {
		t.Errorf("expected empty model, got %q", cfg.Agents.Defaults.Model)
	}
}

func TestDecode_MalformedJSON(t *testing.T) {
	_, err := decode(bytes.NewReader([]byte(`{not valid json`)))
	if err == nil {
		t.Fatal("expected error for malformed JSON, got nil")
	}
}

func TestStorageRoot_Default(t *testing.T) {
	// We test StorageRoot priority: Config > Env Var > Default.
	
	// 1. Config override
	cfg := &Config{Strategic: StrategicConfig{StorageRoot: "config_root"}}
	if got := cfg.StorageRoot(); got != "config_root" {
		t.Errorf("Priority 1 (Config) failed: got %q, want %q", got, "config_root")
	}

	// 2. Env Var override
	cfg2 := &Config{}
	t.Setenv("GOBOT_STORAGE", "env_root")
	if got := cfg2.StorageRoot(); got != "env_root" {
		t.Errorf("Priority 2 (Env) failed: got %q, want %q", got, "env_root")
	}

	// 3. Portable Default (fallback when USERPROFILE is missing/unstable)
	t.Setenv("GOBOT_STORAGE", "")
	origHome := os.Getenv("USERPROFILE")
	os.Unsetenv("USERPROFILE")
	os.Unsetenv("HOME")
	defer os.Setenv("USERPROFILE", origHome)

	cfg3 := &Config{}
	got := cfg3.StorageRoot()
	// When no HOME/USERPROFILE, it should return "gobot_storage" or a joined path.
	if got == "" {
		t.Error("Priority 3 (Default) returned empty string")
	}
}

func TestSave(t *testing.T) {
	tmp := filepath.Join(t.TempDir(), "config.json")
	cfg := &Config{
		Strategic: StrategicConfig{UserEmail: "test@example.com"},
	}
	if err := cfg.Save(tmp); err != nil {
		t.Fatalf("Save failed: %v", err)
	}
	cfg2, err := LoadFrom(tmp)
	if err != nil {
		t.Fatalf("LoadFrom failed: %v", err)
	}
	if cfg2.Strategic.UserEmail != "test@example.com" {
		t.Errorf("got email %q, want %q", cfg2.Strategic.UserEmail, "test@example.com")
	}
}

func TestStorageRoot_Override(t *testing.T) {
	cfg := &Config{Strategic: StrategicConfig{StorageRoot: "custom_storage"}}
	if cfg.StorageRoot() != "custom_storage" {
		t.Errorf("got %q, want custom_storage", cfg.StorageRoot())
	}
}

func TestSecretsRoot(t *testing.T) {
	cfg := &Config{}
	defaultRoot := cfg.StorageRoot()

	tests := []struct {
		name        string
		storageRoot string
		want        string
	}{
		{
			name:        "default storage root",
			storageRoot: "",
			want:        filepath.Join(defaultRoot, "secrets"),
		},
		{
			name:        "custom storage root",
			storageRoot: "custom_root",
			want:        filepath.Join("custom_root", "secrets"),
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			cfg := &Config{Strategic: StrategicConfig{StorageRoot: tc.storageRoot}}
			if got := cfg.SecretsRoot(); got != tc.want {
				t.Errorf("SecretsRoot() = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestGatewayConfig(t *testing.T) {
	input := `{"gateway":{"enabled":true,"host":"0.0.0.0","port":1234}}`
	cfg, err := decode(bytes.NewReader([]byte(input)))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !cfg.Gateway.Enabled {
		t.Error("expected gateway enabled")
	}
	if cfg.Gateway.Host != "0.0.0.0" {
		t.Errorf("got host %q, want 0.0.0.0", cfg.Gateway.Host)
	}
	if cfg.Gateway.Port != 1234 {
		t.Errorf("got port %d, want 1234", cfg.Gateway.Port)
	}
}

func TestLogsRoot(t *testing.T) {
	cfg := &Config{Strategic: StrategicConfig{StorageRoot: "logs_root"}}
	want := filepath.Join("logs_root", "logs")
	if got := cfg.LogsRoot(); got != want {
		t.Errorf("LogsRoot() = %q, want %q", got, want)
	}
}

func TestLogPath(t *testing.T) {
	cfg := &Config{Strategic: StrategicConfig{StorageRoot: "logs_root"}}
	want := filepath.Join("logs_root", "logs", "gobot.log")
	if got := cfg.LogPath("gobot.log"); got != want {
		t.Errorf("LogPath() = %q, want %q", got, want)
	}
}

func TestDefaultModel(t *testing.T) {
	tests := []struct {
		name  string
		model string
		want  string
	}{
		{
			name:  "configured model",
			model: "gemini-2-flash",
			want:  "gemini-2-flash",
		},
		{
			name:  "empty falls back to default",
			model: "",
			want:  "gemini-3-flash-preview",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			cfg := &Config{Agents: AgentsConfig{Defaults: AgentDefaults{Model: tc.model}}}
			if got := cfg.DefaultModel(); got != tc.want {
				t.Errorf("DefaultModel() = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestWorkspacePath(t *testing.T) {
	tests := []struct {
		name    string
		root    string
		subpath []string
		want    string
	}{
		{
			name:    "no subpath",
			root:    "storage",
			subpath: nil,
			want:    filepath.Join("storage", "workspace"),
		},
		{
			name:    "one subpath element",
			root:    "storage",
			subpath: []string{"jobs"},
			want:    filepath.Join("storage", "workspace", "jobs"),
		},
		{
			name:    "multiple subpath elements",
			root:    "storage",
			subpath: []string{"journal", "2026-01-01.md"},
			want:    filepath.Join("storage", "workspace", "journal", "2026-01-01.md"),
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			cfg := &Config{Strategic: StrategicConfig{StorageRoot: tc.root}}
			got := cfg.WorkspacePath(tc.subpath...)
			if got != tc.want {
				t.Errorf("WorkspacePath(%v) = %q, want %q", tc.subpath, got, tc.want)
			}
		})
	}
}

func TestGeminiAPIKey(t *testing.T) {
	cfg := &Config{Providers: ProvidersConfig{Gemini: GeminiConfig{APIKey: "my-key"}}}
	if cfg.GeminiAPIKey() != "my-key" {
		t.Errorf("got %q, want %q", cfg.GeminiAPIKey(), "my-key")
	}
}

func TestGeminiAPIKey_Empty(t *testing.T) {
	cfg := &Config{Strategic: StrategicConfig{StorageRoot: t.TempDir()}}
	t.Setenv("GEMINI_API_KEY", "")
	if cfg.GeminiAPIKey() != "" {
		t.Errorf("expected empty key, got %q", cfg.GeminiAPIKey())
	}
}

func TestDefaultConfigPath(t *testing.T) {
	got := DefaultConfigPath()
	if !strings.HasSuffix(got, filepath.Join(".gobot", "config.json")) {
		t.Errorf("DefaultConfigPath() = %q, want suffix .gobot/config.json", got)
	}
}

func TestLoadFrom_ValidFile(t *testing.T) {
	content := `{"providers":{"gemini":{"apiKey":"file-key"}}}`
	f, err := os.CreateTemp(t.TempDir(), "config-*.json")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString(content); err != nil {
		t.Fatal(err)
	}
	f.Close()

	cfg, err := LoadFrom(f.Name())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Providers.Gemini.APIKey != "file-key" {
		t.Errorf("got apiKey %q, want %q", cfg.Providers.Gemini.APIKey, "file-key")
	}
}

func TestLoadFrom_MissingFile(t *testing.T) {
	cfg, err := LoadFrom(filepath.Join(t.TempDir(), "nonexistent.json"))
	if err != nil {
		t.Fatalf("unexpected error for missing file: %v", err)
	}
	if cfg == nil {
		t.Fatal("expected empty config for missing file, got nil")
	}
}

func TestDecode_ReadError(t *testing.T) {
	_, err := decode(errReader{})
	if err == nil {
		t.Fatal("expected error from failing reader, got nil")
	}
}

func TestDecode_OnlyBOM(t *testing.T) {
	bom := []byte{0xEF, 0xBB, 0xBF}
	_, err := decode(bytes.NewReader(bom))
	if err == nil {
		t.Fatal("expected parse error for BOM-only input, got nil")
	}
}

func TestLoad_DoesNotPanic(_ *testing.T) {
	_, _ = Load()
}

func TestTelegramConfig_AllowFrom(t *testing.T) {
	json := `{"channels":{"telegram":{"token":"tok","allowFrom":["111","222"]}}}`
	cfg, err := decode(bytes.NewReader([]byte(json)))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Channels.Telegram.Token != "tok" {
		t.Errorf("token: got %q, want %q", cfg.Channels.Telegram.Token, "tok")
	}
	if len(cfg.Channels.Telegram.AllowFrom) != 2 {
		t.Errorf("allowFrom length: got %d, want 2", len(cfg.Channels.Telegram.AllowFrom))
	}
	if cfg.Channels.Telegram.AllowFrom[0] != "111" {
		t.Errorf("allowFrom[0]: got %q, want %q", cfg.Channels.Telegram.AllowFrom[0], "111")
	}
}

func TestTelegramToken_FromConfig(t *testing.T) {
	cfg := &Config{Channels: ChannelsConfig{Telegram: TelegramConfig{Token: "cfg-token"}}}
	if cfg.TelegramToken() != "cfg-token" {
		t.Errorf("got %q, want cfg-token", cfg.TelegramToken())
	}
}

func TestTelegramToken_EnvFallback(t *testing.T) {
	cfg := &Config{Strategic: StrategicConfig{StorageRoot: t.TempDir()}}
	t.Setenv("TELEGRAM_BOT_TOKEN", "env-token")
	if cfg.TelegramToken() != "env-token" {
		t.Errorf("got %q, want env-token", cfg.TelegramToken())
	}
}

func TestTelegramToken_Empty(t *testing.T) {
	cfg := &Config{Strategic: StrategicConfig{StorageRoot: t.TempDir()}}
	t.Setenv("TELEGRAM_BOT_TOKEN", "")
	if cfg.TelegramToken() != "" {
		t.Errorf("got %q, want empty", cfg.TelegramToken())
	}
}

func TestMCPEnvFor_StaticValues(t *testing.T) {
	cfg := &Config{
		Tools: ToolsConfig{
			MCPServers: map[string]MCPServerConfig{
				"google-ai-search": {
					Command: "node",
					Args:    []string{"server.js"},
					Env:     map[string]string{"GOOGLE_AI_API_KEY": "static-key-123"},
				},
			},
		},
	}
	env := cfg.MCPEnvFor("google-ai-search")
	if env["GOOGLE_AI_API_KEY"] != "static-key-123" {
		t.Errorf("got %q, want %q", env["GOOGLE_AI_API_KEY"], "static-key-123")
	}
}

func TestMCPEnvFor_UnknownServer(t *testing.T) {
	cfg := &Config{}
	env := cfg.MCPEnvFor("nonexistent-server")
	if len(env) != 0 {
		t.Errorf("expected empty map, got %v", env)
	}
}

func TestMCPEnvFor_NoServers(t *testing.T) {
	cfg := &Config{Strategic: StrategicConfig{}}
	env := cfg.MCPEnvFor("any-server")
	if len(env) != 0 {
		t.Errorf("expected empty map, got %v", env)
	}
}

func TestMCPEnvFor_EmptyValue_NoFallback(t *testing.T) {
	cfg := &Config{
		Strategic: StrategicConfig{StorageRoot: t.TempDir()},
		Tools: ToolsConfig{
			MCPServers: map[string]MCPServerConfig{
				"my-server": {
					Env: map[string]string{"SECRET_KEY": ""},
				},
			},
		},
	}
	env := cfg.MCPEnvFor("my-server")
	if _, ok := env["SECRET_KEY"]; ok {
		t.Errorf("expected SECRET_KEY to be absent (no DPAPI value), got %q", env["SECRET_KEY"])
	}
}

func TestDecode_MCPServers(t *testing.T) {
	// Mirrors the actual tools.mcpServers layout in ~/.gobot/config.json.
	input := `{
		"tools": {
			"exec": {"timeout": 180},
			"mcpServers": {
				"search-srv": {
					"command": "npx",
					"args": ["-y", "search-server"],
					"env": {"API_KEY": "abc123", "DEBUG": ""}
				}
			}
		}
	}`
	cfg, err := decode(bytes.NewReader([]byte(input)))
	if err != nil {
		t.Fatalf("unexpected decode error: %v", err)
	}
	if len(cfg.Tools.MCPServers) != 1 {
		t.Fatalf("expected 1 MCP server, got %d", len(cfg.Tools.MCPServers))
	}
	srv, ok := cfg.Tools.MCPServers["search-srv"]
	if !ok {
		t.Fatal("expected server key 'search-srv' not found")
	}
	if srv.Command != "npx" {
		t.Errorf("command: got %q, want %q", srv.Command, "npx")
	}
	if len(srv.Args) != 2 {
		t.Errorf("args: got %v, want 2 elements", srv.Args)
	}
	if srv.Env["API_KEY"] != "abc123" {
		t.Errorf("env[API_KEY]: got %q, want %q", srv.Env["API_KEY"], "abc123")
	}
	if cfg.Tools.Exec.Timeout != 180 {
		t.Errorf("exec.timeout: got %d, want 180", cfg.Tools.Exec.Timeout)
	}
}

func TestExecTimeout_Default(t *testing.T) {
	cfg := &Config{}
	if got := cfg.ExecTimeout(); got != 2*time.Minute {
		t.Errorf("ExecTimeout() = %v, want 2m (default)", got)
	}
}

func TestExecTimeout_Configured(t *testing.T) {
	cfg := &Config{Tools: ToolsConfig{Exec: ExecConfig{Timeout: 180}}}
	if got := cfg.ExecTimeout(); got != 180*time.Second {
		t.Errorf("ExecTimeout() = %v, want 180s", got)
	}
}

func TestEffectiveMaxToolIterations(t *testing.T) {
	tests := []struct {
		name  string
		limit int
		want  int
	}{
		{"zero value returns 25", 0, 25},
		{"explicit value returns that value", 50, 50},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			cfg := &Config{
				Strategic: StrategicConfig{MaxToolIterations: tc.limit},
			}
			if got := cfg.EffectiveMaxToolIterations(); got != tc.want {
				t.Errorf("EffectiveMaxToolIterations() = %d, want %d", got, tc.want)
			}
		})
	}
}

func TestDecode_StrategicLimits(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name  string
		input string
		want  int
	}{
		{
			name:  "explicit value",
			input: `{"strategic_edition":{"max_tool_iterations":50}}`,
			want:  50,
		},
		{
			name:  "zero/missing value defaults to 25",
			input: `{"strategic_edition":{}}`,
			want:  25,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			cfg, err := decode(bytes.NewReader([]byte(tc.input)))
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got := cfg.EffectiveMaxToolIterations(); got != tc.want {
				t.Errorf("EffectiveMaxToolIterations() = %d, want %d", got, tc.want)
			}
		})
	}
}

func TestHumanInTheLoop(t *testing.T) {
	tests := []struct {
		name string
		hitl bool
		want bool
	}{
		{"hitl enabled", true, true},
		{"hitl disabled", false, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			cfg := &Config{Channels: ChannelsConfig{Telegram: TelegramConfig{HITL: tc.hitl}}}
			if got := cfg.HumanInTheLoop(); got != tc.want {
				t.Errorf("HumanInTheLoop() = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestObservabilityConfig(t *testing.T) {
	input := `{"strategic_edition":{"observability":{"service_name":"test-bot","otlp_endpoint":"localhost:4317","sampling_rate":0.5}}}`
	cfg, err := decode(bytes.NewReader([]byte(input)))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	obs := cfg.Strategic.Observability
	if obs.ServiceName != "test-bot" {
		t.Errorf("got service_name %q, want test-bot", obs.ServiceName)
	}
	if obs.OTLPEndpoint != "localhost:4317" {
		t.Errorf("got otlp_endpoint %q, want localhost:4317", obs.OTLPEndpoint)
	}
	if obs.SamplingRate != 0.5 {
		t.Errorf("got sampling_rate %v, want 0.5", obs.SamplingRate)
	}
}

// TestConfig_SecretsErrorLogging verifies that when the secrets store fails,
// warnings are logged via slog but environment variable fallback still works.
func TestConfig_SecretsErrorLogging(t *testing.T) {
	// Set up a custom slog handler to capture log output.
	var logBuf bytes.Buffer
	handler := slog.NewTextHandler(&logBuf, nil)
	oldDefault := slog.Default()
	slog.SetDefault(slog.New(handler))
	t.Cleanup(func() { slog.SetDefault(oldDefault) })

	// Create a temporary storage root with a corrupted secrets file to force errors.
	tmpDir := t.TempDir()
	workspaceDir := filepath.Join(tmpDir, "workspace")
	if err := os.MkdirAll(workspaceDir, 0o755); err != nil {
		t.Fatal(err)
	}
	// Write corrupted JSON to trigger parse errors.
	secretsFile := filepath.Join(workspaceDir, "dpapi_secrets.json")
	if err := os.WriteFile(secretsFile, []byte("{invalid json"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := &Config{Strategic: StrategicConfig{StorageRoot: tmpDir}}

	// Set environment variables as fallback.
	t.Setenv("GEMINI_API_KEY", "env-gemini-key")
	t.Setenv("ANTHROPIC_API_KEY", "env-anthropic-key")
	t.Setenv("OPENAI_API_KEY", "env-openai-key")
	t.Setenv("OPENAI_BASE_URL", "env-openai-url")
	t.Setenv("GOOGLE_API_KEY", "env-google-key")
	t.Setenv("GOOGLE_CX", "env-google-cx")
	t.Setenv("TELEGRAM_BOT_TOKEN", "env-telegram-token")

	tests := []struct {
		name      string
		getKey    func(*Config) string
		wantValue string
	}{
		{
			name:      "GeminiAPIKey falls back to env",
			getKey:    func(c *Config) string { return c.GeminiAPIKey() },
			wantValue: "env-gemini-key",
		},
		{
			name:      "AnthropicAPIKey falls back to env",
			getKey:    func(c *Config) string { return c.AnthropicAPIKey() },
			wantValue: "env-anthropic-key",
		},
		{
			name:      "OpenAIAPIKey falls back to env",
			getKey:    func(c *Config) string { return c.OpenAIAPIKey() },
			wantValue: "env-openai-key",
		},
		{
			name:      "OpenAIBaseURL falls back to env",
			getKey:    func(c *Config) string { return c.OpenAIBaseURL() },
			wantValue: "env-openai-url",
		},
		{
			name:      "GoogleAPIKey falls back to env",
			getKey:    func(c *Config) string { return c.GoogleAPIKey() },
			wantValue: "env-google-key",
		},
		{
			name:      "GoogleCX falls back to env",
			getKey:    func(c *Config) string { return c.GoogleCX() },
			wantValue: "env-google-cx",
		},
		{
			name:      "TelegramToken falls back to env",
			getKey:    func(c *Config) string { return c.TelegramToken() },
			wantValue: "env-telegram-token",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			logBuf.Reset()
			got := tc.getKey(cfg)
			if got != tc.wantValue {
				t.Errorf("got %q, want %q", got, tc.wantValue)
			}
			// Verify that a warning was logged (secrets store lookup failed).
			logOutput := logBuf.String()
			if !strings.Contains(logOutput, "secrets store lookup failed") {
				t.Errorf("expected warning log, got: %s", logOutput)
			}
		})
	}
}

func TestLockTimeoutDuration(t *testing.T) {
	tests := []struct {
		name    string
		seconds int
		want    time.Duration
	}{
		{
			name:    "configured value used",
			seconds: 60,
			want:    60 * time.Second,
		},
		{
			name:    "zero value defaults to 120s",
			seconds: 0,
			want:    120 * time.Second,
		},
		{
			name:    "negative value defaults to 120s",
			seconds: -1,
			want:    120 * time.Second,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			cfg := &Config{
				Agents: AgentsConfig{
					Defaults: AgentDefaults{
						LockTimeoutSeconds: tc.seconds,
					},
				},
			}
			if got := cfg.LockTimeoutDuration(); got != tc.want {
				t.Errorf("LockTimeoutDuration() = %v, want %v", got, tc.want)
			}
		})
	}
}

var _ io.Reader = errReader{}
