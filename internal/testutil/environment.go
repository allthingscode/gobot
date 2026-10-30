package testutil

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

// RunHermeticTests isolates package-wide fallbacks before any parallel tests run.
// Test executables exit after this returns, so no ambient values need restoring.
func RunHermeticTests(m *testing.M) int {
	root, err := os.MkdirTemp("", "gobot-tests-*")
	if err != nil {
		fmt.Fprintln(os.Stderr, "create test environment:", err)
		return 1
	}
	defer os.RemoveAll(root)
	for key, value := range testEnvironment(root) {
		if err := os.Setenv(key, value); err != nil {
			fmt.Fprintln(os.Stderr, "set test environment:", err)
			return 1
		}
	}
	return m.Run()
}

// IsolateEnvironment gives a serial test its own home, storage and empty secrets
// store. Tests must supply any credentials they need explicitly using dummy data.
func IsolateEnvironment(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	for key, value := range testEnvironment(root) {
		t.Setenv(key, value)
	}
	return filepath.Join(root, "storage")
}

func testEnvironment(root string) map[string]string {
	return map[string]string{
		"HOME":                      root,
		"USERPROFILE":               root,
		"XDG_CONFIG_HOME":           filepath.Join(root, "config"),
		"GOBOT_HOME":                root,
		"GOBOT_STORAGE":             filepath.Join(root, "storage"),
		"GOBOT_ENCRYPTION_KEY_FILE": filepath.Join(root, "encryption.key"),
		"GEMINI_API_KEY":            "",
		"ANTHROPIC_API_KEY":         "",
		"OPENAI_API_KEY":            "",
		"OPENAI_BASE_URL":           "",
		"OPENROUTER_API_KEY":        "",
		"OPENROUTER_BASE_URL":       "",
		"GOOGLE_API_KEY":            "",
		"GOOGLE_CX":                 "",
		"TELEGRAM_BOT_TOKEN":        "",
	}
}
