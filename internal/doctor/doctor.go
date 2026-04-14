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

	"github.com/allthingscode/gobot/internal/agent"
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

// Result represents the outcome of a single health check.
type Result struct {
	Name     string `json:"name"`
	OK       bool   `json:"ok"`
	Detail   string `json:"detail"`
	Critical bool   `json:"critical"`
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

	results := GetResults(cfg, probes)

	fmt.Println("gobot doctor")
	fmt.Println("============")

	anyCriticalFail := false
	for _, c := range results {
		var icon string
		switch {
		case c.OK:
			icon = "OK "
		case !c.OK && c.Critical:
			icon = "ERR"
			anyCriticalFail = true
		case !c.OK && !c.Critical:
			icon = "WRN"
		}
		fmt.Printf("  [%s] %-22s", icon, c.Name)
		if c.Detail != "" {
			fmt.Printf(" — %s", c.Detail)
		}
		fmt.Println()
	}

	fmt.Printf("\n%d checks in %s\n", len(results), time.Since(start).Round(time.Millisecond))

	if anyCriticalFail {
		return fmt.Errorf("one or more critical health checks failed")
	}
	return nil
}

// GetResults performs all health checks and returns the results.
// Pass probes as nil to skip live connectivity checks.
func GetResults(cfg *config.Config, probes *Probes) []Result {
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
	r := func(c Result, crit bool) Result { c.Critical = crit; return c }

	checks := []Result{ //nolint:prealloc // capacity depends on resResults and conResults which require iteration to compute
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

	// Check for old-format circuit breaker durations (C-138)
	for name, bc := range cfg.Resilience.CircuitBreakers {
		if bc.Window == "" || bc.Timeout == "" {
			checks = append(checks, Result{
				Name:     "breaker migration: " + name,
				OK:       false,
				Detail:   "duration fields are empty; migrate to string format (e.g. \"60s\")",
				Critical: false,
			})
		}
	}

	// Add Concurrency checks (F-056)
	conResults := checkConcurrency()
	for _, res := range conResults {
		checks = append(checks, r(res, false))
	}

	return checks
}

func checkStorageRoot(cfg *config.Config) Result {
	root := cfg.StorageRoot()
	info, err := os.Stat(root)
	if err != nil {
		return Result{Name: "storage root", OK: false, Detail: fmt.Sprintf("%s: %v", root, err)}
	}
	if !info.IsDir() {
		return Result{Name: "storage root", OK: false, Detail: fmt.Sprintf("%s is not a directory", root)}
	}
	return Result{Name: "storage root", OK: true, Detail: root}
}

func checkWorkspace(cfg *config.Config) Result {
	ws := filepath.Join(cfg.StorageRoot(), "workspace")
	tmp, err := os.CreateTemp(ws, "gobot-doctor-*")
	if err != nil {
		return Result{Name: "workspace writable", OK: false, Detail: fmt.Sprintf("%s: %v", ws, err)}
	}
	_ = tmp.Close()
	_ = os.Remove(tmp.Name())
	return Result{Name: "workspace writable", OK: true, Detail: ws}
}

func checkLogs(cfg *config.Config) Result {
	logs := filepath.Join(cfg.StorageRoot(), "logs")
	if err := os.MkdirAll(logs, 0o755); err != nil {
		return Result{Name: "logs directory", OK: false, Detail: fmt.Sprintf("%v", err)}
	}
	return Result{Name: "logs directory", OK: true, Detail: logs}
}

func checkAPIKey(cfg *config.Config) Result {
	key := cfg.GeminiAPIKey()
	if key == "" {
		key = os.Getenv("GOOGLE_API_KEY")
	}
	if key == "" {
		return Result{Name: "gemini api key", OK: false, Detail: "not found in config or GOOGLE_API_KEY env"}
	}
	var masked string
	if len(key) < 8 {
		masked = "***"
	} else {
		masked = key[:4] + "..." + key[len(key)-4:]
	}
	slog.Debug("api key found", "masked", masked) //nolint:gosec // G706: masked value is safe for logging
	return Result{Name: "gemini api key", OK: true, Detail: masked}
}

// checkTelegram validates the Telegram bot token.
// If probe is nil, only the presence of the token is verified.
func checkTelegram(token string, probe func(string) (string, error)) Result {
	// #nosec G101 - "REAUTH_REQUIRED" is a placeholder string, not a secret.
	if token == "" || token == "REAUTH_REQUIRED" {
		return Result{Name: "telegram", OK: false, Detail: "token not configured or reauth required"}
	}
	if probe == nil {
		return Result{Name: "telegram", OK: true, Detail: "token present (live check skipped)"}
	}
	username, err := probe(token)
	if err != nil {
		return Result{Name: "telegram", OK: false, Detail: err.Error()}
	}
	return Result{Name: "telegram", OK: true, Detail: username}
}

// checkGeminiLive validates the Gemini API key with a live API call.
// If probe is nil, only the presence of the key is verified.
func checkGeminiLive(apiKey string, probe func(string) error) Result {
	if apiKey == "" {
		return Result{Name: "gemini live", OK: false, Detail: "no api key"}
	}
	if probe == nil {
		return Result{Name: "gemini live", OK: true, Detail: "key present (live check skipped)"}
	}
	if err := probe(apiKey); err != nil {
		return Result{Name: "gemini live", OK: false, Detail: err.Error()}
	}
	return Result{Name: "gemini live", OK: true, Detail: "model responded"}
}

// checkGoogleToken reads secrets/google_token.json and reports the token expiry.
func checkGoogleToken(secretsRoot string) Result {
	return checkTokenFile("google token", filepath.Join(secretsRoot, "google_token.json"))
}

// checkGmailToken reads secrets/gmail/token.json and reports the token expiry.
func checkGmailToken(secretsRoot string) Result {
	return checkTokenFile("gmail token", filepath.Join(secretsRoot, "gmail", "token.json"))
}

// checkTokenFile reads a token JSON file and reports its expiry.
func buildExpiredTokenDetail(expiry time.Time, hasRefresh bool) string {
	if time.Now().After(expiry) {
		if hasRefresh {
			return "access token timed out — will refresh automatically"
		}
		diff := time.Since(expiry)
		if diff < 24*time.Hour {
			return fmt.Sprintf("EXPIRED %d hour(s) ago (no refresh token)", int(diff.Hours()))
		}
		return fmt.Sprintf("EXPIRED %d day(s) ago (no refresh token)", int(diff.Hours()/24))
	}

	remaining := time.Until(expiry)
	detail := ""
	switch {
	case remaining < 1*time.Hour:
		detail = fmt.Sprintf("expires in %d minute(s)", int(remaining.Minutes()))
	case remaining < 24*time.Hour:
		detail = fmt.Sprintf("expires in %d hour(s)", int(remaining.Hours()))
	default:
		detail = fmt.Sprintf("valid, expires in %d day(s)", int(remaining.Hours()/24))
	}

	if hasRefresh {
		detail += " — will refresh automatically"
	}

	return detail
}

func checkTokenFile(name, path string) Result {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return Result{Name: name, OK: false, Detail: fmt.Sprintf("not found: %s", path)}
		}
		return Result{Name: name, OK: false, Detail: err.Error()}
	}
	var tok tokenExpiry
	if err := json.Unmarshal(data, &tok); err != nil {
		return Result{Name: name, OK: false, Detail: fmt.Sprintf("invalid JSON: %v", err)}
	}

	hasRefresh := tok.RefreshToken != ""

	if tok.Expiry.IsZero() {
		detail := "present (no expiry field)"
		if hasRefresh {
			detail += " — will refresh"
		}
		return Result{Name: name, OK: true, Detail: detail}
	}

	ok := !time.Now().After(tok.Expiry) || hasRefresh
	return Result{Name: name, OK: ok, Detail: buildExpiredTokenDetail(tok.Expiry, hasRefresh)}
}

// checkJobsDir verifies the cron jobs directory exists and has .md job files.
func checkJobsDir(cfg *config.Config) Result {
	dir := filepath.Join(cfg.StorageRoot(), "workspace", "jobs")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return Result{Name: "jobs directory", OK: false, Detail: fmt.Sprintf("%s: %v", dir, err)}
	}
	count := 0
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(strings.ToLower(e.Name()), ".md") {
			count++
		}
	}
	if count == 0 {
		return Result{Name: "jobs directory", OK: true, Detail: fmt.Sprintf("%s (no .md jobs)", dir)}
	}
	return Result{Name: "jobs directory", OK: true, Detail: fmt.Sprintf("%d job(s) in %s", count, dir)}
}

// checkResilience returns results for all registered circuit breakers.
func checkResilience() []Result {
	breakers := resilience.All()
	if len(breakers) == 0 {
		return []Result{{Name: "resilience", OK: true, Detail: "no circuit breakers registered"}}
	}

	results := make([]Result, 0, len(breakers))
	for name, b := range breakers {
		state := b.State()
		stats := resilience.GetStats(name)
		detail := fmt.Sprintf("state: %s, succ: %d, fail: %d, rej: %d",
			state, stats.Successes, stats.Failures, stats.Rejections)

		ok := true
		if state == "open" {
			ok = false
		}
		results = append(results, Result{
			Name:   "breaker: " + name,
			OK:     ok,
			Detail: detail,
		})
	}
	return results
}

// checkConcurrency returns results for all session locks that have recorded metrics.
func checkConcurrency() []Result {
	metrics := agent.GetLockMetrics()
	if len(metrics) == 0 {
		return []Result{{Name: "concurrency", OK: true, Detail: "no active session locks"}}
	}

	results := make([]Result, 0, len(metrics))
	for name, m := range metrics {
		detail := fmt.Sprintf("contention: %d, max_wait: %s, total_hold: %s",
			m.ContentionCount,
			m.MaxWaitTime.Round(time.Millisecond),
			m.TotalHoldTime.Round(time.Millisecond))

		results = append(results, Result{
			Name:   "lock: " + name,
			OK:     true, // advisory
			Detail: detail,
		})
	}
	return results
}
