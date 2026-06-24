package doctor

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/allthingscode/gobot/internal/config"
)

func checkAPIKey(cfg *config.Config) Result {
	type entry struct {
		name string
		key  string
	}
	candidates := []entry{
		{"gemini", cfg.GeminiAPIKey()},
		{"anthropic", cfg.AnthropicAPIKey()},
		{"openai", cfg.OpenAIAPIKey()},
		{"openrouter", cfg.OpenRouterAPIKey()},
	}
	var found []string
	for _, e := range candidates {
		if e.key != "" {
			found = append(found, e.name)
		}
	}
	if len(found) == 0 {
		return Result{
			Name:        "llm api key",
			OK:          false,
			Detail:      "no key found — set GEMINI_API_KEY, ANTHROPIC_API_KEY, OPENAI_API_KEY, or OPENROUTER_API_KEY",
			Remediation: "Set a required LLM API key environment variable or use 'gobot secrets set'.",
		}
	}
	return Result{Name: "llm api key", OK: true, Detail: strings.Join(found, ", ")}
}

// checkTelegram validates the Telegram bot token.
// If probe is nil, only the presence of the token is verified.
func checkTelegram(token string, probe func(string) (string, error)) Result {
	// #nosec G101 - "REAUTH_REQUIRED" is a placeholder string, not a secret.
	if token == "" || token == "REAUTH_REQUIRED" {
		return Result{
			Name:        "telegram",
			OK:          false,
			Detail:      "token not configured or reauth required",
			Remediation: "Provide a Telegram token in config.json or environment variable, or run 'gobot reauth'.",
		}
	}
	if probe == nil {
		return Result{Name: "telegram", OK: true, Detail: "token present (live check skipped)"}
	}
	username, err := probe(token)
	if err != nil {
		return Result{
			Name:        "telegram",
			OK:          false,
			Detail:      err.Error(),
			Remediation: "Check your Telegram bot token and internet connection.",
		}
	}
	return Result{Name: "telegram", OK: true, Detail: username}
}

// checkGeminiLive validates the Gemini API key with a live API call.
// If probe is nil, only the presence of the key is verified.
func checkGeminiLive(apiKey string, probe func(string) error) Result {
	if apiKey == "" {
		return Result{
			Name:        "gemini live",
			OK:          false,
			Detail:      "no api key",
			Remediation: "Set GEMINI_API_KEY environment variable.",
		}
	}
	if probe == nil {
		return Result{Name: "gemini live", OK: true, Detail: "key present (live check skipped)"}
	}
	if err := probe(apiKey); err != nil {
		return Result{
			Name:        "gemini live",
			OK:          false,
			Detail:      err.Error(),
			Remediation: "Verify your Gemini API key and quota in Google AI Studio.",
		}
	}
	return Result{Name: "gemini live", OK: true, Detail: "model responded"}
}

// checkBrowser verifies browser availability based on the configured mode.
func checkBrowser(cfg config.BrowserConfig, lookPath func(string) (string, error)) Result {
	switch {
	case cfg.DebugPort > 0:
		return Result{
			Name:   "browser",
			OK:     true,
			Detail: fmt.Sprintf("remote debug mode (port %d) — ensure Chrome is running with --remote-debugging-port=%d", cfg.DebugPort, cfg.DebugPort),
		}
	case cfg.Headless:
		path, ok := findBrowser(lookPath)
		if !ok {
			return Result{
				Name:        "browser",
				OK:          false,
				Detail:      "Chrome/Chromium not found in PATH — browser-based tools will be disabled",
				Remediation: "Install Google Chrome or Chromium, or ensure it is in your system PATH.",
			}
		}
		return Result{Name: "browser", OK: true, Detail: path}
	default:
		return Result{
			Name:        "browser",
			OK:          false,
			Detail:      "browser not configured (set browser.headless=true or browser.debug_port) — browser-based tools will be disabled",
			Remediation: "Set browser.headless=true in config.json to enable browser-based tools.",
		}
	}
}

// findBrowser searches for common browser executables based on the operating system.
func findBrowser(lookPath func(string) (string, error)) (string, bool) {
	var names []string
	switch runtime.GOOS {
	case "windows":
		names = []string{"chrome.exe", "msedge.exe", "brave.exe"}
	case "darwin":
		names = []string{
			"google-chrome",
			"chromium",
			"microsoft-edge",
			"brave-browser",
			"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
			"/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
			"/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
		}
	default: // linux, etc.
		names = []string{
			"google-chrome",
			"google-chrome-stable",
			"chromium",
			"chromium-browser",
			"chrome",
			"microsoft-edge",
			"brave-browser",
		}
	}

	for _, name := range names {
		// If it's an absolute path, check if it exists and is executable
		if filepath.IsAbs(name) {
			if info, err := os.Stat(name); err == nil && !info.IsDir() {
				return name, true
			}
			continue
		}
		path, err := lookPath(name)
		if err == nil {
			return path, true
		}
	}
	return "", false
}
