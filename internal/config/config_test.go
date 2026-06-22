//nolint:testpackage // requires unexported config internals for testing
package config

import (
	"bytes"
	"errors"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

type errReader struct{}

func (errReader) Read(_ []byte) (int, error) { return 0, errors.New("read error") }

func TestDecode_NoBOM(t *testing.T) {
	t.Parallel()
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
	t.Parallel()
	bom := []byte{0xEF, 0xBB, 0xBF} //nolint:prealloc // BOM literal; preallocating would obscure intent
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
	t.Parallel()
	cfg, err := decode(bytes.NewReader([]byte(`{}`)))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Agents.Defaults.Model != "" {
		t.Errorf("expected empty model, got %q", cfg.Agents.Defaults.Model)
	}
}

func TestDecode_MalformedJSON(t *testing.T) {
	t.Parallel()
	_, err := decode(bytes.NewReader([]byte(`{not valid json`)))
	if err == nil {
		t.Fatal("expected error for malformed JSON, got nil")
	}
}

func TestStorageRoot_Default(t *testing.T) {
	// We test StorageRoot priority: Config > Env Var > Default.

	// 1. Config override
	cfg := &Config{Runtime: RuntimeConfig{StorageRoot: "config_root"}}
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
	_ = os.Unsetenv("USERPROFILE")
	_ = os.Unsetenv("HOME")
	defer func() { _ = os.Setenv("USERPROFILE", origHome) }()

	cfg3 := &Config{}
	got := cfg3.StorageRoot()
	// When no HOME/USERPROFILE, it should return "gobot_storage" or a joined path.
	if got == "" {
		t.Error("Priority 3 (Default) returned empty string")
	}
}

func TestStorageRoot_GobotHomeDerived(t *testing.T) {
	// GOBOT_STORAGE wins over GOBOT_HOME (existing installs never relocate).
	t.Setenv("GOBOT_HOME", filepath.Join("home", "root"))
	t.Setenv("GOBOT_STORAGE", "explicit_storage")
	cfg := &Config{}
	if got := cfg.StorageRoot(); got != "explicit_storage" {
		t.Errorf("GOBOT_STORAGE should win over GOBOT_HOME: got %q, want %q", got, "explicit_storage")
	}

	// With GOBOT_STORAGE unset, data derives from GOBOT_HOME (single knob).
	t.Setenv("GOBOT_STORAGE", "")
	want := filepath.Join("home", "root", "data")
	if got := cfg.StorageRoot(); got != want {
		t.Errorf("GOBOT_HOME-derived storage: got %q, want %q", got, want)
	}

	// config.json storage_root still takes top priority over both env vars.
	cfgOverride := &Config{Runtime: RuntimeConfig{StorageRoot: "config_root"}}
	if got := cfgOverride.StorageRoot(); got != "config_root" {
		t.Errorf("config storage_root should win over env: got %q, want %q", got, "config_root")
	}
}

func TestSave(t *testing.T) {
	t.Parallel()
	tmp := filepath.Join(t.TempDir(), "config.json")
	cfg := &Config{
		Runtime: RuntimeConfig{UserEmail: "test@example.com"},
	}
	if err := cfg.Save(tmp); err != nil {
		t.Fatalf("Save failed: %v", err)
	}
	cfg2, err := LoadFrom(tmp)
	if err != nil {
		t.Fatalf("LoadFrom failed: %v", err)
	}
	if cfg2.Runtime.UserEmail != "test@example.com" {
		t.Errorf("got email %q, want %q", cfg2.Runtime.UserEmail, "test@example.com")
	}
}

func TestStorageRoot_Override(t *testing.T) {
	t.Parallel()
	cfg := &Config{Runtime: RuntimeConfig{StorageRoot: "custom_storage"}}
	if cfg.StorageRoot() != "custom_storage" {
		t.Errorf("got %q, want custom_storage", cfg.StorageRoot())
	}
}

func TestSecretsRoot(t *testing.T) {
	t.Parallel()
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
			t.Parallel()
			cfg := &Config{Runtime: RuntimeConfig{StorageRoot: tc.storageRoot}}
			if got := cfg.SecretsRoot(); got != tc.want {
				t.Errorf("SecretsRoot() = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestGatewayConfig(t *testing.T) {
	t.Parallel()
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

func TestGatewayDefaultsLoopback(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name        string
		input       string
		wantHost    string
		wantWebAddr string
	}{
		{
			name:        "empty host defaults to loopback",
			input:       `{"gateway":{"enabled":true}}`,
			wantHost:    "127.0.0.1",
			wantWebAddr: "",
		},
		{
			name:        "explicit host preserved",
			input:       `{"gateway":{"enabled":true,"host":"0.0.0.0"}}`,
			wantHost:    "0.0.0.0",
			wantWebAddr: "",
		},
		{
			name:        "dashboard enabled defaults web_addr to loopback",
			input:       `{"gateway":{"enabled":true,"dashboard_enabled":true}}`,
			wantHost:    "127.0.0.1",
			wantWebAddr: "127.0.0.1:0",
		},
		{
			name:        "explicit web_addr preserved",
			input:       `{"gateway":{"enabled":true,"dashboard_enabled":true,"web_addr":"0.0.0.0:9000"}}`,
			wantHost:    "127.0.0.1",
			wantWebAddr: "0.0.0.0:9000",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			cfg, err := decode(bytes.NewReader([]byte(tc.input)))
			if err != nil {
				t.Fatalf("decode: %v", err)
			}
			if cfg.Gateway.Host != tc.wantHost {
				t.Errorf("host: got %q, want %q", cfg.Gateway.Host, tc.wantHost)
			}
			if cfg.Gateway.WebAddr != tc.wantWebAddr {
				t.Errorf("web_addr: got %q, want %q", cfg.Gateway.WebAddr, tc.wantWebAddr)
			}
		})
	}
}

func TestGatewayDefaultsNoAllInterfacesBinding(t *testing.T) {
	t.Parallel()
	cfg, err := decode(bytes.NewReader([]byte(`{"gateway":{"enabled":true,"dashboard_enabled":true}}`)))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if strings.HasPrefix(cfg.Gateway.Host, "0.0.0.0") {
		t.Errorf("default host must not bind all interfaces, got %q", cfg.Gateway.Host)
	}
	if strings.HasPrefix(cfg.Gateway.WebAddr, "0.0.0.0") {
		t.Errorf("default web_addr must not bind all interfaces, got %q", cfg.Gateway.WebAddr)
	}
}

func TestLogsRoot(t *testing.T) {
	t.Parallel()
	cfg := &Config{Runtime: RuntimeConfig{StorageRoot: "logs_root"}}
	want := filepath.Join("logs_root", "logs")
	if got := cfg.LogsRoot(); got != want {
		t.Errorf("LogsRoot() = %q, want %q", got, want)
	}
}

func TestLogPath(t *testing.T) {
	t.Parallel()
	cfg := &Config{Runtime: RuntimeConfig{StorageRoot: "logs_root"}}
	want := filepath.Join("logs_root", "logs", "gobot.log")
	if got := cfg.LogPath("gobot.log"); got != want {
		t.Errorf("LogPath() = %q, want %q", got, want)
	}
}

func TestDefaultModel(t *testing.T) {
	t.Parallel()
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
			t.Parallel()
			cfg := &Config{Agents: AgentsConfig{Defaults: AgentDefaults{Model: tc.model}}}
			if got := cfg.DefaultModel(); got != tc.want {
				t.Errorf("DefaultModel() = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestWorkspacePath(t *testing.T) {
	t.Parallel()
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
			t.Parallel()
			cfg := &Config{Runtime: RuntimeConfig{StorageRoot: tc.root}}
			got := cfg.WorkspacePath("", tc.subpath...)
			if got != tc.want {
				t.Errorf("WorkspacePath(%v) = %q, want %q", tc.subpath, got, tc.want)
			}
		})
	}
}

func TestGeminiAPIKey(t *testing.T) {
	t.Parallel()
	cfg := &Config{Providers: ProvidersConfig{Gemini: GeminiConfig{APIKey: "my-key"}}}
	if cfg.GeminiAPIKey() != "my-key" {
		t.Errorf("got %q, want %q", cfg.GeminiAPIKey(), "my-key")
	}
}

func TestGeminiAPIKey_Empty(t *testing.T) {
	cfg := &Config{Runtime: RuntimeConfig{StorageRoot: t.TempDir()}}
	t.Setenv("GEMINI_API_KEY", "")
	if cfg.GeminiAPIKey() != "" {
		t.Errorf("expected empty key, got %q", cfg.GeminiAPIKey())
	}
}

func TestDefaultConfigPath(t *testing.T) {
	t.Parallel()
	got := DefaultConfigPath()
	if !strings.HasSuffix(got, filepath.Join(".gobot", "config.json")) {
		t.Errorf("DefaultConfigPath() = %q, want suffix .gobot/config.json", got)
	}
}

func TestLoadFrom_ValidFile(t *testing.T) {
	t.Parallel()
	content := `{"providers":{"gemini":{"apiKey":"file-key"}}}`
	f, err := os.CreateTemp(t.TempDir(), "config-*.json")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString(content); err != nil {
		t.Fatal(err)
	}
	_ = f.Close()

	cfg, err := LoadFrom(f.Name())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Providers.Gemini.APIKey != "file-key" {
		t.Errorf("got apiKey %q, want %q", cfg.Providers.Gemini.APIKey, "file-key")
	}
}

func TestLoadFrom_MissingFile(t *testing.T) {
	t.Parallel()
	cfg, err := LoadFrom(filepath.Join(t.TempDir(), "nonexistent.json"))
	if err != nil {
		t.Fatalf("unexpected error for missing file: %v", err)
	}
	if cfg == nil {
		t.Fatal("expected empty config for missing file, got nil")
	}
}

func TestLoadConfig_UnknownField(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name        string
		content     string
		wantErrPart string
	}{
		{
			name:        "top-level unknown key",
			content:     `{"typo_key":true}`,
			wantErrPart: "typo_key",
		},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			cfgPath := filepath.Join(t.TempDir(), "config.json")
			if err := os.WriteFile(cfgPath, []byte(tc.content), 0o600); err != nil {
				t.Fatalf("write config: %v", err)
			}
			_, err := LoadFrom(cfgPath)
			if err == nil {
				t.Fatal("expected error for unknown top-level key, got nil")
			}
			if !strings.Contains(err.Error(), tc.wantErrPart) {
				t.Fatalf("error %q does not contain %q", err.Error(), tc.wantErrPart)
			}
		})
	}
}

func TestLoadConfig_PartialConfig(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name      string
		content   string
		wantLevel string
	}{
		{
			name:      "logging-only partial config",
			content:   `{"logging":{"level":"DEBUG"}}`,
			wantLevel: "DEBUG",
		},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			cfgPath := filepath.Join(t.TempDir(), "config.json")
			if err := os.WriteFile(cfgPath, []byte(tc.content), 0o600); err != nil {
				t.Fatalf("write config: %v", err)
			}
			cfg, err := LoadFrom(cfgPath)
			if err != nil {
				t.Fatalf("LoadFrom() unexpected error: %v", err)
			}
			if cfg.Logging.Level != tc.wantLevel {
				t.Fatalf("Logging.Level = %q, want %q", cfg.Logging.Level, tc.wantLevel)
			}
		})
	}
}

func TestDecode_ReadError(t *testing.T) {
	t.Parallel()
	_, err := decode(errReader{})
	if err == nil {
		t.Fatal("expected error from failing reader, got nil")
	}
}

func TestDecode_OnlyBOM(t *testing.T) {
	t.Parallel()
	bom := []byte{0xEF, 0xBB, 0xBF} //nolint:prealloc // BOM literal; preallocating would obscure intent
	_, err := decode(bytes.NewReader(bom))
	if err == nil {
		t.Fatal("expected parse error for BOM-only input, got nil")
	}
}

func TestLoad_DoesNotPanic(t *testing.T) {
	t.Parallel()
	_, _ = Load()
}

func TestTelegramConfig_AllowFrom(t *testing.T) {
	t.Parallel()
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
	t.Parallel()
	cfg := &Config{Channels: ChannelsConfig{Telegram: TelegramConfig{Token: "cfg-token"}}}
	if cfg.TelegramToken() != "cfg-token" {
		t.Errorf("got %q, want cfg-token", cfg.TelegramToken())
	}
}

func TestTelegramToken_EnvFallback(t *testing.T) {
	cfg := &Config{Runtime: RuntimeConfig{StorageRoot: t.TempDir()}}
	t.Setenv("TELEGRAM_BOT_TOKEN", "env-token")
	if cfg.TelegramToken() != "env-token" {
		t.Errorf("got %q, want env-token", cfg.TelegramToken())
	}
}

func TestTelegramToken_Empty(t *testing.T) {
	cfg := &Config{Runtime: RuntimeConfig{StorageRoot: t.TempDir()}}
	t.Setenv("TELEGRAM_BOT_TOKEN", "")
	if cfg.TelegramToken() != "" {
		t.Errorf("got %q, want empty", cfg.TelegramToken())
	}
}

func TestMCPEnvFor_StaticValues(t *testing.T) {
	t.Parallel()
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
	t.Parallel()
	cfg := &Config{}
	env := cfg.MCPEnvFor("nonexistent-server")
	if len(env) != 0 {
		t.Errorf("expected empty map, got %v", env)
	}
}

func TestMCPEnvFor_NoServers(t *testing.T) {
	t.Parallel()
	cfg := &Config{Runtime: RuntimeConfig{}}
	env := cfg.MCPEnvFor("any-server")
	if len(env) != 0 {
		t.Errorf("expected empty map, got %v", env)
	}
}

func TestMCPEnvFor_EmptyValue_NoFallback(t *testing.T) {
	t.Parallel()
	cfg := &Config{
		Runtime: RuntimeConfig{StorageRoot: t.TempDir()},
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
	t.Parallel()
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
	t.Parallel()
	cfg := &Config{}
	if got := cfg.ExecTimeout(); got != 2*time.Minute {
		t.Errorf("ExecTimeout() = %v, want 2m (default)", got)
	}
}

func TestExecTimeout_Configured(t *testing.T) {
	t.Parallel()
	cfg := &Config{Tools: ToolsConfig{Exec: ExecConfig{Timeout: 180}}}
	if got := cfg.ExecTimeout(); got != 180*time.Second {
		t.Errorf("ExecTimeout() = %v, want 180s", got)
	}
}

func TestEffectiveMaxToolIterations(t *testing.T) {
	t.Parallel()
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
			t.Parallel()
			cfg := &Config{
				Runtime: RuntimeConfig{MaxToolIterations: tc.limit},
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
	t.Parallel()
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
			t.Parallel()
			cfg := &Config{Channels: ChannelsConfig{Telegram: TelegramConfig{HITL: tc.hitl}}}
			if got := cfg.HumanInTheLoop(); got != tc.want {
				t.Errorf("HumanInTheLoop() = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestObservabilityConfig(t *testing.T) {
	t.Parallel()
	input := `{"strategic_edition":{"observability":{"service_name":"test-bot","otlp_endpoint":"localhost:4317","sampling_rate":0.5}}}`
	cfg, err := decode(bytes.NewReader([]byte(input)))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	obs := cfg.Runtime.Observability
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

func TestConfig_SecretsErrorLogging(t *testing.T) {
	var logBuf bytes.Buffer
	handler := slog.NewTextHandler(&logBuf, nil)
	oldDefault := slog.Default()
	slog.SetDefault(slog.New(handler))
	t.Cleanup(func() { slog.SetDefault(oldDefault) })
	tmpDir := t.TempDir()
	workspaceDir := filepath.Join(tmpDir, "workspace")
	if err := os.MkdirAll(workspaceDir, 0o755); err != nil {
		t.Fatal(err)
	}
	secretsFile := filepath.Join(workspaceDir, "dpapi_secrets.json")
	if err := os.WriteFile(secretsFile, []byte("{invalid json"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := &Config{Runtime: RuntimeConfig{StorageRoot: tmpDir}}
	t.Setenv("GEMINI_API_KEY", "env-gemini-key")
	t.Setenv("ANTHROPIC_API_KEY", "env-anthropic-key")
	t.Setenv("OPENAI_API_KEY", "env-openai-key")
	t.Setenv("OPENAI_BASE_URL", "env-openai-url")
	t.Setenv("GOOGLE_API_KEY", "env-google-key")
	t.Setenv("GOOGLE_CX", "env-google-cx")
	t.Setenv("TELEGRAM_BOT_TOKEN", "env-telegram-token")
	runSecretsFallbackTests(t, cfg, &logBuf)
}

func runSecretsFallbackTests(t *testing.T, cfg *Config, logBuf *bytes.Buffer) {
	t.Helper()
	type kv struct{ k, v string }
	cases := []kv{
		{"GeminiAPIKey falls back to env", "env-gemini-key"},
		{"AnthropicAPIKey falls back to env", "env-anthropic-key"},
		{"OpenAIAPIKey falls back to env", "env-openai-key"},
		{"OpenAIBaseURL falls back to env", "env-openai-url"},
		{"GoogleAPIKey falls back to env", "env-google-key"},
		{"GoogleCX falls back to env", "env-google-cx"},
		{"TelegramToken falls back to env", "env-telegram-token"},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.k, func(t *testing.T) {
			logBuf.Reset()
			got := getConfigValue(cfg, tc.k)
			if got != tc.v {
				t.Errorf("got %q, want %q", got, tc.v)
			}
			if !strings.Contains(logBuf.String(), "secrets store lookup failed") {
				t.Errorf("expected warning log")
			}
		})
	}
}

func getConfigValue(cfg *Config, key string) string {
	switch key {
	case "GeminiAPIKey falls back to env":
		return cfg.GeminiAPIKey()
	case "AnthropicAPIKey falls back to env":
		return cfg.AnthropicAPIKey()
	case "OpenAIAPIKey falls back to env":
		return cfg.OpenAIAPIKey()
	case "OpenAIBaseURL falls back to env":
		return cfg.OpenAIBaseURL()
	case "GoogleAPIKey falls back to env":
		return cfg.GoogleAPIKey()
	case "GoogleCX falls back to env":
		return cfg.GoogleCX()
	case "TelegramToken falls back to env":
		return cfg.TelegramToken()
	default:
		return ""
	}
}

func TestLockTimeoutDuration(t *testing.T) {
	t.Parallel()
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
			t.Parallel()
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

func TestEmbeddingModel(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name  string
		field string
		want  string
	}{
		{
			name:  "empty field returns default",
			field: "",
			want:  "text-embedding-004",
		},
		{
			name:  "explicit value is returned as-is",
			field: "my-custom-model",
			want:  "my-custom-model",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			cfg := &Config{Runtime: RuntimeConfig{EmbeddingModel: tc.field}}
			if got := cfg.EmbeddingModel(); got != tc.want {
				t.Errorf("EmbeddingModel() = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestLoggingSettings(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name       string
		level      string
		format     string
		wantLevel  slog.Level
		wantFormat string
	}{
		{"default", "", "", slog.LevelInfo, "text"},
		{"debug", "DEBUG", "", slog.LevelDebug, "text"},
		{"warn", "warn", "", slog.LevelWarn, "text"},
		{"error", "Error", "", slog.LevelError, "text"},
		{"json", "", "json", slog.LevelInfo, "json"},
		{"json_caps", "", "JSON", slog.LevelInfo, "json"},
		{"mixed", "DEBUG", "json", slog.LevelDebug, "json"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			cfg := &Config{Logging: LoggingConfig{Level: tc.level, Format: tc.format}}
			if got := cfg.LogLevel(); got != tc.wantLevel {
				t.Errorf("LogLevel() = %v, want %v", got, tc.wantLevel)
			}
			if got := cfg.LogFormat(); got != tc.wantFormat {
				t.Errorf("LogFormat() = %v, want %v", got, tc.wantFormat)
			}
		})
	}
}

var _ io.Reader = errReader{}

func TestBreaker_Parsing(t *testing.T) {
	t.Parallel()
	cfg := &Config{}
	cfg.Resilience.CircuitBreakers = map[string]BreakerConfig{
		"valid":   {MaxFailures: 10, Window: "2m", Timeout: "45s"},
		"invalid": {MaxFailures: 5, Window: "not-a-duration", Timeout: ""},
	}

	// Test valid parsing
	maxFail, window, timeout := cfg.Breaker("valid")
	if maxFail != 10 || window != 2*time.Minute || timeout != 45*time.Second {
		t.Errorf("valid breaker: got (%d, %v, %v), want (10, 2m, 45s)", maxFail, window, timeout)
	}

	// Test fallback for invalid/empty
	maxFail, window, timeout = cfg.Breaker("invalid")
	if maxFail != 5 || window != 60*time.Second || timeout != 30*time.Second {
		t.Errorf("invalid breaker: got (%d, %v, %v), want (5, 60s, 30s)", maxFail, window, timeout)
	}

	// Test fallback for missing
	maxFail, window, timeout = cfg.Breaker("missing")
	if maxFail != 5 || window != 60*time.Second || timeout != 30*time.Second {
		t.Errorf("missing breaker: got (%d, %v, %v), want (5, 60s, 30s)", maxFail, window, timeout)
	}
}

// --- C-326: legacy snake_case -> canonical camelCase key migration ---

// AC2: a config written with the old snake_case keys still loads with identical values.
func TestNormalizeLegacyKeys_LoadsLegacySnakeCase(t *testing.T) {
	t.Parallel()
	legacy := `{
	  "logging": {"max_size_mb": 50, "max_backups": 5, "max_age_days": 30},
	  "browser": {"debug_port": 9222},
	  "resilience": {"circuit_breakers": {"llm": {"max_failures": 7, "window": "60s", "timeout": "30s"}}},
	  "context": {"session_token_budget": 12345, "compaction_summary_turns": 9},
	  "gateway": {"dashboard_enabled": true, "auth_token": "tok", "web_addr": "127.0.0.1:8080"},
	  "tools": {"high_risk": ["shell_exec"]}
	}`
	cfg, err := decode(bytes.NewReader([]byte(legacy)))
	if err != nil {
		t.Fatalf("decode legacy config: %v", err)
	}
	checks := []struct {
		name string
		got  any
		want any
	}{
		{"logging.maxSizeMB", cfg.Logging.MaxSizeMB, 50},
		{"logging.maxBackups", cfg.Logging.MaxBackups, 5},
		{"logging.maxAgeDays", cfg.Logging.MaxAgeDays, 30},
		{"browser.debugPort", cfg.Browser.DebugPort, 9222},
		{"resilience.circuitBreakers[llm].maxFailures", cfg.Resilience.CircuitBreakers["llm"].MaxFailures, uint32(7)},
		{"context.sessionTokenBudget", cfg.Context.SessionTokenBudget, 12345},
		{"context.compactionSummaryTurns", cfg.Context.CompactionSummaryTurns, 9},
		{"gateway.dashboardEnabled", cfg.Gateway.DashboardEnabled, true},
		{"gateway.authToken", cfg.Gateway.AuthToken, "tok"},
		{"gateway.webAddr", cfg.Gateway.WebAddr, "127.0.0.1:8080"},
		{"tools.highRisk", strings.Join(cfg.Tools.HighRisk, ","), "shell_exec"},
	}
	for _, c := range checks {
		if !reflect.DeepEqual(c.got, c.want) {
			t.Errorf("%s = %v (%T), want %v (%T)", c.name, c.got, c.got, c.want, c.want)
		}
	}
}

// A canonical (camelCase) config loads unchanged through the normalization pass.
func TestNormalizeLegacyKeys_CanonicalLoadsUnchanged(t *testing.T) {
	t.Parallel()
	canonical := `{"logging":{"maxSizeMB":42},"gateway":{"authToken":"abc"},"tools":{"highRisk":["x"]}}`
	cfg, err := decode(bytes.NewReader([]byte(canonical)))
	if err != nil {
		t.Fatalf("decode canonical config: %v", err)
	}
	if cfg.Logging.MaxSizeMB != 42 || cfg.Gateway.AuthToken != "abc" || len(cfg.Tools.HighRisk) != 1 {
		t.Errorf("canonical keys not loaded: logging=%+v gateway=%+v tools=%+v", cfg.Logging, cfg.Gateway, cfg.Tools)
	}
}

// AC1: Marshal never emits a migrated snake_case key; it emits the canonical form.
func TestMarshal_EmitsCanonicalKeysOnly(t *testing.T) {
	t.Parallel()
	cfg := &Config{
		Logging:    LoggingConfig{MaxSizeMB: 1, MaxBackups: 2, MaxAgeDays: 3},
		Browser:    BrowserConfig{DebugPort: 9222},
		Resilience: ResilienceConfig{CircuitBreakers: map[string]BreakerConfig{"llm": {MaxFailures: 4}}},
		Context:    ContextConfig{SessionTokenBudget: 5, CompactionSummaryTurns: 6},
		Gateway:    GatewayConfig{DashboardEnabled: true, AuthToken: "t", WebAddr: "a"},
		Tools:      ToolsConfig{HighRisk: []string{"x"}},
	}
	data, err := cfg.Marshal()
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	out := string(data)
	for _, k := range []string{
		"max_size_mb", "max_backups", "max_age_days", "debug_port", "circuit_breakers",
		"max_failures", "session_token_budget", "compaction_summary_turns",
		"dashboard_enabled", "auth_token", "web_addr", "high_risk",
	} {
		if strings.Contains(out, `"`+k+`"`) {
			t.Errorf("Marshal output still contains legacy key %q", k)
		}
	}
	for _, k := range []string{
		"maxSizeMB", "debugPort", "circuitBreakers", "maxFailures", "sessionTokenBudget",
		"compactionSummaryTurns", "dashboardEnabled", "authToken", "webAddr", "highRisk",
	} {
		if !strings.Contains(out, `"`+k+`"`) {
			t.Errorf("Marshal output missing canonical key %q", k)
		}
	}
}

// AC3: when both the legacy and canonical keys are present, the canonical value wins and
// exactly one WARN naming the deprecated key is logged.
//
//nolint:paralleltest // mutates the global slog default to capture warnings
func TestNormalizeLegacyKeys_BothPresent_CanonicalWinsWarnsOnce(t *testing.T) {
	var logBuf bytes.Buffer
	oldDefault := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&logBuf, nil)))
	t.Cleanup(func() { slog.SetDefault(oldDefault) })

	input := `{"gateway":{"auth_token":"legacy","authToken":"canonical"}}`
	cfg, err := decode(bytes.NewReader([]byte(input)))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if cfg.Gateway.AuthToken != "canonical" {
		t.Errorf("canonical did not win: got %q", cfg.Gateway.AuthToken)
	}
	if got := strings.Count(logBuf.String(), "deprecated_key=auth_token"); got != 1 {
		t.Errorf("expected exactly one warn for auth_token, got %d; log:\n%s", got, logBuf.String())
	}
}

// AC4: Load(legacy) -> Marshal yields canonical, stable output (what `config reformat`
// relies on to migrate a legacy file deterministically).
func TestNormalizeLegacyKeys_ReformatIsCanonicalAndIdempotent(t *testing.T) {
	t.Parallel()
	legacy := `{"logging":{"max_size_mb":7},"context":{"session_token_budget":8}}`
	cfg1, err := decode(bytes.NewReader([]byte(legacy)))
	if err != nil {
		t.Fatalf("decode legacy: %v", err)
	}
	data1, err := cfg1.Marshal()
	if err != nil {
		t.Fatalf("marshal1: %v", err)
	}
	if strings.Contains(string(data1), "max_size_mb") || strings.Contains(string(data1), "session_token_budget") {
		t.Errorf("reformatted output still has legacy keys:\n%s", data1)
	}
	cfg2, err := decode(bytes.NewReader(data1))
	if err != nil {
		t.Fatalf("decode reformatted: %v", err)
	}
	data2, err := cfg2.Marshal()
	if err != nil {
		t.Fatalf("marshal2: %v", err)
	}
	if !bytes.Equal(data1, data2) {
		t.Errorf("reformat not idempotent:\n%s\n---\n%s", data1, data2)
	}
}

// Path-scoping safety: a legacy-looking key inside a user-controlled map (an mcpServers
// env var) is NOT rewritten - only the known config paths are normalized.
func TestNormalizeLegacyKeys_DoesNotTouchUserMaps(t *testing.T) {
	t.Parallel()
	input := `{"tools":{"mcpServers":{"srv":{"command":"c","args":[],"env":{"auth_token":"keepme"}}}}}`
	cfg, err := decode(bytes.NewReader([]byte(input)))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	srv, ok := cfg.Tools.MCPServers["srv"]
	if !ok {
		t.Fatal("mcpServers[srv] missing")
	}
	if srv.Env["auth_token"] != "keepme" {
		t.Errorf("user map key was rewritten: env=%+v", srv.Env)
	}
}

// The legacy->canonical alias map is the single source of truth for deprecated keys.
// C-326 maps snake_case spellings to camelCase; C-327 adds the root-level
// strategic_edition -> runtime block rename onto the same path.
func TestLegacyKeyRenames_SingleSourceOfTruth(t *testing.T) {
	t.Parallel()
	for _, renames := range legacyKeyRenames {
		for legacy, canonical := range renames {
			if canonical == "" {
				t.Errorf("alias %q maps to an empty canonical key", legacy)
			}
		}
	}
	if legacyKeyRenames["gateway"]["auth_token"] != "authToken" {
		t.Errorf("expected gateway.auth_token -> authToken in alias map")
	}
	// C-327: the strategic_edition block is renamed to runtime via the root path.
	if legacyKeyRenames[""]["strategic_edition"] != "runtime" {
		t.Errorf("expected root-level strategic_edition -> runtime alias (C-327)")
	}
}

// AC2 (C-327): the block formerly keyed strategic_edition now serializes under "runtime",
// and a config using the legacy strategic_edition key still loads identically.
func TestRuntimeBlock_LegacyStrategicEditionAlias(t *testing.T) {
	t.Parallel()
	legacyCfg, err := decode(bytes.NewReader([]byte(`{"strategic_edition":{"user_email":"a@b.com","storage_root":"/data"}}`)))
	if err != nil {
		t.Fatalf("decode legacy strategic_edition: %v", err)
	}
	canonicalCfg, err := decode(bytes.NewReader([]byte(`{"runtime":{"user_email":"a@b.com","storage_root":"/data"}}`)))
	if err != nil {
		t.Fatalf("decode runtime: %v", err)
	}
	if !reflect.DeepEqual(legacyCfg.Runtime, canonicalCfg.Runtime) {
		t.Errorf("legacy strategic_edition did not load identically to runtime:\n legacy=%+v\n runtime=%+v", legacyCfg.Runtime, canonicalCfg.Runtime)
	}
	if legacyCfg.Runtime.UserEmail != "a@b.com" || legacyCfg.Runtime.StorageRoot != "/data" {
		t.Errorf("runtime values not populated from legacy key: %+v", legacyCfg.Runtime)
	}
	data, err := canonicalCfg.Marshal()
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if out := string(data); strings.Contains(out, "strategic_edition") || !strings.Contains(out, `"runtime"`) {
		t.Errorf("Marshal must emit \"runtime\" and not \"strategic_edition\"; got:\n%s", out)
	}
}
