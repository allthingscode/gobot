//nolint:testpackage // exercises config's package-wide TestMain fixture
package config

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestConfigEnvironment_IgnoresAmbientCredentials(t *testing.T) {
	t.Parallel()
	if ambient := os.Getenv("GOBOT_TEST_AMBIENT_ROOT"); ambient != "" {
		// Check paths before any validator or getter could open a secrets store.
		if (&Config{}).StorageRoot() == ambient || DefaultConfigPath() == filepath.Join(ambient, ".gobot", "config.json") {
			t.Fatal("package TestMain did not replace ambient storage/config paths")
		}
		assertEmptyCredentialFallbacks(t)
		return
	}

	ambient := t.TempDir()
	cmd := exec.CommandContext(t.Context(), os.Args[0], "-test.run=^TestConfigEnvironment_IgnoresAmbientCredentials$") //nolint:gosec // runs only this test binary with a fixed selector
	cmd.Env = append(os.Environ(), "GOBOT_TEST_AMBIENT_ROOT="+ambient)
	for _, key := range []string{"HOME", "USERPROFILE", "GOBOT_HOME", "GOBOT_STORAGE", "APPDATA", "LOCALAPPDATA", "XDG_CONFIG_HOME", "XDG_DATA_HOME"} {
		cmd.Env = append(cmd.Env, key+"="+ambient)
	}
	cmd.Env = append(cmd.Env, "GOBOT_ENCRYPTION_KEY_FILE="+filepath.Join(ambient, "encryption.key"))
	// All nine envKey arguments in config_secrets.go; URLs are loopback only.
	for _, key := range []string{"GEMINI_API_KEY", "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY", "GOOGLE_API_KEY", "GOOGLE_CX", "TELEGRAM_BOT_TOKEN"} {
		cmd.Env = append(cmd.Env, key+"=123456:dummy-b062-credential")
	}
	for _, key := range []string{"OPENAI_BASE_URL", "OPENROUTER_BASE_URL"} {
		cmd.Env = append(cmd.Env, key+"=http://127.0.0.1:1")
	}
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("config with dummy ambient credentials: %v\n%s", err, out)
	}
}

func assertEmptyCredentialFallbacks(t *testing.T) {
	t.Helper()
	cfg := &Config{}
	for name, get := range map[string]func() string{
		"GEMINI_API_KEY": cfg.GeminiAPIKey, "ANTHROPIC_API_KEY": cfg.AnthropicAPIKey,
		"OPENAI_API_KEY": cfg.OpenAIAPIKey, "OPENAI_BASE_URL": cfg.OpenAIBaseURL,
		"OPENROUTER_API_KEY": cfg.OpenRouterAPIKey, "OPENROUTER_BASE_URL": cfg.OpenRouterBaseURL,
		"GOOGLE_API_KEY": cfg.GoogleAPIKey, "GOOGLE_CX": cfg.GoogleCX,
		"TELEGRAM_BOT_TOKEN": cfg.TelegramToken,
	} {
		if get() != "" {
			t.Errorf("ambient %s survived isolation", name)
		}
	}
	cfg.Channels.Telegram.Enabled = true
	cfg.Channels.Telegram.AllowFrom = []string{"123456"}
	result := NewValidator(cfg).Validate()
	assertFieldError(t, result, "providers.api_key", true)
	assertFieldError(t, result, "channels.telegram.token", true)
}
