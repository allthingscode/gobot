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
	name     string
	ok       bool
	detail   string
	critical bool // if true, failure halts startup
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

	// Critical checks halt startup on failure.
	// Advisory checks print [WARN] but never block the bot from starting.
	r := func(c result, crit bool) result { c.critical = crit; return c }

	checks := []result{
		r(checkStorageRoot(cfg), true),
		r(checkWorkspace(cfg), true),
		r(checkLogs(cfg), false),
		r(checkAPIKey(cfg), true),
		r(checkTelegram(cfg.TelegramToken(), p.ProbeTelegram), true),
		r(checkGeminiLive(apiKey, p.ProbeGemini), false),
		r(checkGoogleToken(secretsRoot), false),
		r(checkGmailToken(secretsRoot), false),
		r(checkJobsDir(cfg), false),
	}

	fmt.Println("gobot doctor")
	fmt.Println("============")

	anyCriticalFail := false
	for _, c := range checks {
		var icon string
		switch {
		case c.ok:
			icon = "OK "
		case c.critical:
			icon = "ERR"
			anyCriticalFail = true
		default:
			icon = "WRN"
		}
		fmt.Printf("  [%s] %-22s", icon, c.name)
		if c.detail != "" {
			fmt.Printf(" — %s", c.detail)
		}
		fmt.Println()
	}

	fmt.Printf("\n%d checks in %s\n", len(checks), time.Since(start).Round(time.Millisecond))

	if anyCriticalFail {
		return fmt.Errorf("one or more critical health checks failed")
	}
	return nil
}

func checkStorageRoot(cfg *config.Config) result {
	root := cfg.StorageRoot()
	info, err := os.Stat(root)
	if err != nil {
		return result{name: "storage root", ok: false, detail: fmt.Sprintf("%s: %v", root, err)}
	}
	if !info.IsDir() {
		return result{name: "storage root", ok: false, detail: fmt.Sprintf("%s is not a directory", root)}
	}
	return result{name: "storage root", ok: true, detail: root}
}

func checkWorkspace(cfg *config.Config) result {
	ws := filepath.Join(cfg.StorageRoot(), "workspace")
	tmp, err := os.CreateTemp(ws, "gobot-doctor-*")
	if err != nil {
		return result{name: "workspace writable", ok: false, detail: fmt.Sprintf("%s: %v", ws, err)}
	}
	tmp.Close()
	os.Remove(tmp.Name())
	return result{name: "workspace writable", ok: true, detail: ws}
}

func checkLogs(cfg *config.Config) result {
	logs := filepath.Join(cfg.StorageRoot(), "logs")
	if err := os.MkdirAll(logs, 0o755); err != nil {
		return result{name: "logs directory", ok: false, detail: fmt.Sprintf("%v", err)}
	}
	return result{name: "logs directory", ok: true, detail: logs}
}

func checkAPIKey(cfg *config.Config) result {
	key := cfg.GeminiAPIKey()
	if key == "" {
		key = os.Getenv("GOOGLE_API_KEY")
	}
	if key == "" {
		return result{name: "gemini api key", ok: false, detail: "not found in config or GOOGLE_API_KEY env"}
	}
	masked := key[:4] + "..." + key[len(key)-4:]
	slog.Debug("api key found", "masked", masked)
	return result{name: "gemini api key", ok: true, detail: masked}
}

// checkTelegram validates the Telegram bot token.
// If probe is nil, only the presence of the token is verified.
func checkTelegram(token string, probe func(string) (string, error)) result {
	if token == "" {
		return result{name: "telegram", ok: false, detail: "token not configured"}
	}
	if probe == nil {
		return result{name: "telegram", ok: true, detail: "token present (live check skipped)"}
	}
	username, err := probe(token)
	if err != nil {
		return result{name: "telegram", ok: false, detail: err.Error()}
	}
	return result{name: "telegram", ok: true, detail: username}
}

// checkGeminiLive validates the Gemini API key with a live API call.
// If probe is nil, only the presence of the key is verified.
func checkGeminiLive(apiKey string, probe func(string) error) result {
	if apiKey == "" {
		return result{name: "gemini live", ok: false, detail: "no api key"}
	}
	if probe == nil {
		return result{name: "gemini live", ok: true, detail: "key present (live check skipped)"}
	}
	if err := probe(apiKey); err != nil {
		return result{name: "gemini live", ok: false, detail: err.Error()}
	}
	return result{name: "gemini live", ok: true, detail: "model responded"}
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
			return result{name: name, ok: false, detail: fmt.Sprintf("not found: %s", path)}
		}
		return result{name: name, ok: false, detail: err.Error()}
	}
	var tok tokenExpiry
	if err := json.Unmarshal(data, &tok); err != nil {
		return result{name: name, ok: false, detail: fmt.Sprintf("invalid JSON: %v", err)}
	}
	if tok.Expiry.IsZero() {
		return result{name: name, ok: true, detail: "present (no expiry field)"}
	}
	days := int(time.Until(tok.Expiry).Hours() / 24)
	if days < 0 {
		return result{name: name, ok: false, detail: fmt.Sprintf("EXPIRED %d days ago", -days)}
	}
	if days == 0 {
		return result{name: name, ok: true, detail: "expires today — consider refreshing"}
	}
	return result{name: name, ok: true, detail: fmt.Sprintf("valid, expires in %d days", days)}
}

// checkJobsDir verifies the cron jobs directory exists and has .md job files.
func checkJobsDir(cfg *config.Config) result {
	dir := filepath.Join(cfg.StorageRoot(), "workspace", "jobs")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return result{name: "jobs directory", ok: false, detail: fmt.Sprintf("%s: %v", dir, err)}
	}
	count := 0
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(strings.ToLower(e.Name()), ".md") {
			count++
		}
	}
	if count == 0 {
		return result{name: "jobs directory", ok: true, detail: fmt.Sprintf("%s (no .md jobs)", dir)}
	}
	return result{name: "jobs directory", ok: true, detail: fmt.Sprintf("%d job(s) in %s", count, dir)}
}
