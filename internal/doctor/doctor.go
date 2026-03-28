// Package doctor implements the gobot health check (equivalent of strategic_doctor.py).
package doctor

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/allthingscode/gobot/internal/config"
)

// Probes holds optional live connectivity probe functions.
// Set a field to nil to skip that live check (reported as "skipped").
type Probes struct {
	// ProbeTelegram validates the bot token via Telegram's getMe API.
	// Returns the bot @username on success.
	ProbeTelegram func(token string) (username string, err error)
	// ProbeGemini validates the Gemini API key with a minimal live call.
	ProbeGemini func(apiKey string) error
}

type result struct {
	name   string
	ok     bool
	detail string
}

// tokenExpiry is a minimal struct for reading the expiry field from OAuth2 token files.
type tokenExpiry struct {
	Expiry time.Time `json:"expiry"`
}

// Run performs all health checks and prints a report. Returns non-nil if any check fails.
// Pass probes as nil to skip live connectivity checks.
func Run(cfg *config.Config, probes *Probes) error {
	start := time.Now()

	var p Probes
	if probes != nil {
		p = *probes
	}

	apiKey := cfg.GeminiAPIKey()
	if apiKey == "" {
		apiKey = os.Getenv("GOOGLE_API_KEY")
	}

	secretsRoot := filepath.Join(cfg.StorageRoot(), "secrets")

	checks := []result{
		checkStorageRoot(cfg),
		checkWorkspace(cfg),
		checkLogs(cfg),
		checkAPIKey(cfg),
		checkTelegram(cfg.TelegramToken(), p.ProbeTelegram),
		checkGeminiLive(apiKey, p.ProbeGemini),
		checkGoogleToken(secretsRoot),
		checkGmailToken(secretsRoot),
		checkJobsDir(cfg),
	}

	fmt.Println("gobot doctor")
	fmt.Println("============")

	anyFail := false
	for _, c := range checks {
		icon := "OK "
		if !c.ok {
			icon = "ERR"
			anyFail = true
		}
		fmt.Printf("  [%s] %-22s", icon, c.name)
		if c.detail != "" {
			fmt.Printf(" — %s", c.detail)
		}
		fmt.Println()
	}

	fmt.Printf("\n%d checks in %s\n", len(checks), time.Since(start).Round(time.Millisecond))

	if anyFail {
		return fmt.Errorf("one or more health checks failed")
	}
	return nil
}

func checkStorageRoot(cfg *config.Config) result {
	root := cfg.StorageRoot()
	info, err := os.Stat(root)
	if err != nil {
		return result{"storage root", false, fmt.Sprintf("%s: %v", root, err)}
	}
	if !info.IsDir() {
		return result{"storage root", false, fmt.Sprintf("%s is not a directory", root)}
	}
	return result{"storage root", true, root}
}

func checkWorkspace(cfg *config.Config) result {
	ws := filepath.Join(cfg.StorageRoot(), "workspace")
	tmp, err := os.CreateTemp(ws, "gobot-doctor-*")
	if err != nil {
		return result{"workspace writable", false, fmt.Sprintf("%s: %v", ws, err)}
	}
	tmp.Close()
	os.Remove(tmp.Name())
	return result{"workspace writable", true, ws}
}

func checkLogs(cfg *config.Config) result {
	logs := filepath.Join(cfg.StorageRoot(), "logs")
	if err := os.MkdirAll(logs, 0o755); err != nil {
		return result{"logs directory", false, fmt.Sprintf("%v", err)}
	}
	return result{"logs directory", true, logs}
}

func checkAPIKey(cfg *config.Config) result {
	key := cfg.GeminiAPIKey()
	if key == "" {
		key = os.Getenv("GOOGLE_API_KEY")
	}
	if key == "" {
		return result{"gemini api key", false, "not found in config or GOOGLE_API_KEY env"}
	}
	masked := key[:4] + "..." + key[len(key)-4:]
	slog.Debug("api key found", "masked", masked)
	return result{"gemini api key", true, masked}
}

// checkTelegram validates the Telegram bot token.
// If probe is nil, only the presence of the token is verified.
func checkTelegram(token string, probe func(string) (string, error)) result {
	if token == "" {
		return result{"telegram", false, "token not configured"}
	}
	if probe == nil {
		return result{"telegram", true, "token present (live check skipped)"}
	}
	username, err := probe(token)
	if err != nil {
		return result{"telegram", false, err.Error()}
	}
	return result{"telegram", true, username}
}

// checkGeminiLive validates the Gemini API key with a live API call.
// If probe is nil, only the presence of the key is verified.
func checkGeminiLive(apiKey string, probe func(string) error) result {
	if apiKey == "" {
		return result{"gemini live", false, "no api key"}
	}
	if probe == nil {
		return result{"gemini live", true, "key present (live check skipped)"}
	}
	if err := probe(apiKey); err != nil {
		return result{"gemini live", false, err.Error()}
	}
	return result{"gemini live", true, "model responded"}
}

// checkGoogleToken reads secrets/google_token.json and reports the token expiry.
func checkGoogleToken(secretsRoot string) result {
	return checkTokenFile("google token", filepath.Join(secretsRoot, "google_token.json"))
}

// checkGmailToken reads secrets/token.json and reports the token expiry.
func checkGmailToken(secretsRoot string) result {
	return checkTokenFile("gmail token", filepath.Join(secretsRoot, "token.json"))
}

// checkTokenFile reads a token JSON file and reports its expiry.
func checkTokenFile(name, path string) result {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return result{name, false, fmt.Sprintf("not found: %s", path)}
		}
		return result{name, false, err.Error()}
	}
	var tok tokenExpiry
	if err := json.Unmarshal(data, &tok); err != nil {
		return result{name, false, fmt.Sprintf("invalid JSON: %v", err)}
	}
	if tok.Expiry.IsZero() {
		return result{name, true, "present (no expiry field)"}
	}
	days := int(time.Until(tok.Expiry).Hours() / 24)
	if days < 0 {
		return result{name, false, fmt.Sprintf("EXPIRED %d days ago", -days)}
	}
	if days == 0 {
		return result{name, true, "expires today — consider refreshing"}
	}
	return result{name, true, fmt.Sprintf("valid, expires in %d days", days)}
}

// checkJobsDir verifies the cron jobs directory exists and has .md job files.
func checkJobsDir(cfg *config.Config) result {
	dir := filepath.Join(cfg.StorageRoot(), "workspace", "jobs")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return result{"jobs directory", false, fmt.Sprintf("%s: %v", dir, err)}
	}
	count := 0
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(strings.ToLower(e.Name()), ".md") {
			count++
		}
	}
	if count == 0 {
		return result{"jobs directory", true, fmt.Sprintf("%s (no .md jobs)", dir)}
	}
	return result{"jobs directory", true, fmt.Sprintf("%d job(s) in %s", count, dir)}
}
