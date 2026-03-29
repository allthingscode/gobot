package config

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
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
	input := append(bom, json...)

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
	cfg := &Config{}
	if cfg.StorageRoot() != `D:\Gobot_Storage` {
		t.Errorf("got %q, want default storage root", cfg.StorageRoot())
	}
}

func TestStorageRoot_Override(t *testing.T) {
	cfg := &Config{Strategic: StrategicConfig{StorageRoot: `E:\CustomStorage`}}
	if cfg.StorageRoot() != `E:\CustomStorage` {
		t.Errorf("got %q, want override storage root", cfg.StorageRoot())
	}
}

func TestSecretsRoot(t *testing.T) {
	tests := []struct {
		name        string
		storageRoot string
		want        string
	}{
		{
			name:        "default storage root",
			storageRoot: "",
			want:        filepath.Join(`D:\Gobot_Storage`, "secrets"),
		},
		{
			name:        "custom storage root",
			storageRoot: `E:\Custom`,
			want:        filepath.Join(`E:\Custom`, "secrets"),
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
			root:    `D:\Gobot_Storage`,
			subpath: nil,
			want:    filepath.Join(`D:\Gobot_Storage`, "workspace"),
		},
		{
			name:    "one subpath element",
			root:    `D:\Gobot_Storage`,
			subpath: []string{"jobs"},
			want:    filepath.Join(`D:\Gobot_Storage`, "workspace", "jobs"),
		},
		{
			name:    "multiple subpath elements",
			root:    `D:\Gobot_Storage`,
			subpath: []string{"journal", "2026-01-01.md"},
			want:    filepath.Join(`D:\Gobot_Storage`, "workspace", "journal", "2026-01-01.md"),
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
	cfg := &Config{}
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
	f.WriteString(content)
	f.Close()

	cfg, err := LoadFrom(f.Name())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Providers.Gemini.APIKey != "file-key" {
		t.Errorf("got %q, want %q", cfg.Providers.Gemini.APIKey, "file-key")
	}
}

func TestLoadFrom_MissingFile(t *testing.T) {
	_, err := LoadFrom(filepath.Join(t.TempDir(), "nonexistent.json"))
	if err == nil {
		t.Fatal("expected error for missing file, got nil")
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

func TestLoad_DoesNotPanic(t *testing.T) {
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
	cfg := &Config{}
	t.Setenv("TELEGRAM_BOT_TOKEN", "env-token")
	if cfg.TelegramToken() != "env-token" {
		t.Errorf("got %q, want env-token", cfg.TelegramToken())
	}
}

func TestTelegramToken_Empty(t *testing.T) {
	cfg := &Config{}
	t.Setenv("TELEGRAM_BOT_TOKEN", "")
	if cfg.TelegramToken() != "" {
		t.Errorf("got %q, want empty", cfg.TelegramToken())
	}
}

var _ io.Reader = errReader{}
