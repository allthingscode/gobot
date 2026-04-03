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
	"github.com/allthingscode/gobot/internal/resilience"
)

// Probes holds optional live connectivity probe functions.
// Set a field to nil to skip that live check (reported as "skipped").
type Probes struct {
	// ProbeTelegram validates the bot token via Telegram's getMe API.
	// Returns the bot @username on success.
	ProbeTelegram func(token string) (username string, err error)
	// ProbeGemini validates the Gemini API key with a minimal live call.
	ProbeGemini func(apiKey string) error
	// ProbeGmail validates Gmail OAuth2 credentials can produce an access token.
	// gmailSecretsPath is the directory containing token.json (e.g. secrets/gmail).
	ProbeGmail func(gmailSecretsPath string) error
}

type result struct {
	name     string
	ok       bool
	detail   string
	critical bool // if true, failure halts startup
}

// tokenExpiry is a minimal struct for reading the expiry field and refresh_token from OAuth2 token files.
type tokenExpiry struct {
	Expiry       time.Time `json:"expiry"`
	RefreshToken string    `json:"refresh_token"`
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
		r(checkTelegram(cfg.TelegramToken(), p.ProbeTelegram), false),
		r(checkGeminiLive(apiKey, p.ProbeGemini), false),
		r(checkGoogleToken(secretsRoot), false),
		r(checkGmailToken(secretsRoot), false),
		r(checkJobsDir(cfg), false),
	}

	// Add Resilience checks (F-054)
	// Proactively register configured breakers so they show up in the report
	for name := range cfg.Resilience.CircuitBreakers {
		if resilience.Get(name) == nil {
			maxFail, window, timeout := cfg.Breaker(name)
			resilience.New(name, maxFail, window, timeout)
		}
	}

	resResults := checkResilience()
	for _, res := range resResults {
		checks = append(checks, r(res, false))
	}

	fmt.Println("gobot doctor")
	fmt.Println("============")

	anyCriticalFail := false
	for _, c := range checks {
		var icon string
		switch {
		case c.ok:
			icon = "OK "
		case !c.ok && c.critical:
			icon = "ERR"
			anyCriticalFail = true
		case !c.ok && !c.critical:
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
	var masked string
	if len(key) < 8 {
		masked = "***"
	} else {
		masked = key[:4] + "..." + key[len(key)-4:]
	}
	slog.Debug("api key found", "masked", masked)
	return result{name: "gemini api key", ok: true, detail: masked}
}

// checkTelegram validates the Telegram bot token.
// If probe is nil, only the presence of the token is verified.
func checkTelegram(token string, probe func(string) (string, error)) result {
	if token == "" || token == "REAUTH_REQUIRED" {
		return result{name: "telegram", ok: false, detail: "token not configured or reauth required"}
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

// checkGmailToken reads secrets/gmail/token.json and reports the token expiry.
func checkGmailToken(secretsRoot string) result {
	return checkTokenFile("gmail token", filepath.Join(secretsRoot, "gmail", "token.json"))
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

	hasRefresh := tok.RefreshToken != ""

	if tok.Expiry.IsZero() {
		detail := "present (no expiry field)"
		if hasRefresh {
			detail += " — will refresh"
		}
		return result{name: name, ok: true, detail: detail}
	}

	if time.Now().After(tok.Expiry) {
		if hasRefresh {
			return result{name: name, ok: true, detail: "access token timed out — will refresh automatically"}
		}
		diff := time.Since(tok.Expiry)
		if diff < 24*time.Hour {
			return result{name: name, ok: false, detail: fmt.Sprintf("EXPIRED %d hour(s) ago (no refresh token)", int(diff.Hours()))}
		}
		return result{name: name, ok: false, detail: fmt.Sprintf("EXPIRED %d day(s) ago (no refresh token)", int(diff.Hours()/24))}
	}

	remaining := time.Until(tok.Expiry)
	detail := ""
	if remaining < 1*time.Hour {
		detail = fmt.Sprintf("expires in %d minute(s)", int(remaining.Minutes()))
	} else if remaining < 24*time.Hour {
		detail = fmt.Sprintf("expires in %d hour(s)", int(remaining.Hours()))
	} else {
		detail = fmt.Sprintf("valid, expires in %d day(s)", int(remaining.Hours()/24))
	}

	if hasRefresh {
		detail += " — will refresh automatically"
	}

	return result{name: name, ok: true, detail: detail}
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

// checkResilience returns results for all registered circuit breakers.
func checkResilience() []result {
	breakers := resilience.All()
	if len(breakers) == 0 {
		return []result{{name: "resilience", ok: true, detail: "no circuit breakers registered"}}
	}

	var results []result
	for name, b := range breakers {
		state := b.State()
		stats := resilience.GetStats(name)
		detail := fmt.Sprintf("state: %s, succ: %d, fail: %d, rej: %d",
			state, stats.Successes, stats.Failures, stats.Rejections)

		ok := true
		if state == "open" {
			ok = false
		}
		results = append(results, result{
			name:   "breaker: " + name,
			ok:     ok,
			detail: detail,
		})
	}
	return results
}
