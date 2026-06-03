// Package doctor implements the gobot health check (equivalent of strategic_doctor.py).
package doctor

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/resilience"
	"github.com/allthingscode/gobot/internal/secrets"
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
	// LookPath is used to find executables in the system PATH.
	// Defaults to exec.LookPath if nil.
	LookPath func(name string) (string, error)
}

// Result represents the outcome of a single health check.
type Result struct {
	Name        string `json:"name"`
	OK          bool   `json:"ok"`
	Detail      string `json:"detail"`
	Remediation string `json:"remediation,omitempty"`
	Critical    bool   `json:"critical"`
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

	anyCriticalFail := printReport(results)

	fmt.Printf("\n%d checks in %s\n", len(results), time.Since(start).Round(time.Millisecond))

	if anyCriticalFail {
		return fmt.Errorf("one or more critical health checks failed")
	}
	return nil
}

func printReport(results []Result) bool {
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
		if !c.OK && c.Remediation != "" {
			fmt.Printf(" [Remediation: %s]", c.Remediation)
		}
		fmt.Println()
	}
	return anyCriticalFail
}

// geminiLiveChecks returns a Gemini live-probe result if a key is configured, otherwise nil.
func geminiLiveChecks(key string, probe func(string) error, r func(Result, bool) Result) []Result {
	if key == "" {
		return nil
	}
	return []Result{r(checkGeminiLive(key, probe), false)}
}

// GetResults performs all health checks and returns the results.
// Pass probes as nil to skip live connectivity checks.
func GetResults(cfg *config.Config, probes *Probes) []Result {
	var p Probes
	if probes != nil {
		p = *probes
	}
	if p.LookPath == nil {
		p.LookPath = exec.LookPath
	}

	geminiKey := cfg.GeminiAPIKey()
	if geminiKey == "" {
		geminiKey = os.Getenv("GOOGLE_API_KEY")
	}

	secretsRoot := filepath.Join(cfg.StorageRoot(), "secrets")

	// Critical checks halt startup on failure.
	// Advisory checks print [WARN] but never block the bot from starting.
	r := func(c Result, crit bool) Result { c.Critical = crit; return c }

	checks := []Result{ //nolint:prealloc // capacity depends on resResults and conResults which require iteration to compute
		r(checkStorageRoot(cfg), true),
		r(checkWorkspace(cfg), true),
		r(checkSecurityStore(cfg), true),
		r(checkSecretsRoundtrip(cfg), false),
		r(checkEncryptionKey(), false),
		r(checkPlaintextSecrets(cfg), false),
		r(checkHITL(cfg), false),
		r(checkLogs(cfg), false),
		r(checkAPIKey(cfg), true),
		r(checkTelegram(cfg.TelegramToken(), p.ProbeTelegram), false),
		r(checkGoogleOAuthSecrets(cfg), false),
		r(checkGoogleToken(secretsRoot), false),
		r(checkGmailToken(secretsRoot), false),
		r(checkJobsDir(cfg), false),
		r(checkBrowser(cfg.Browser, p.LookPath), false),
		r(checkAuthorization(cfg), false),
	}

	// Only probe Gemini live if Gemini is actually configured.
	checks = append(checks, geminiLiveChecks(geminiKey, p.ProbeGemini, r)...)

	// Add Resilience checks (F-054)
	checks = append(checks, getResilienceResults(cfg, r)...)

	// Add Concurrency checks (F-056)
	conResults := checkConcurrency()
	for _, res := range conResults {
		checks = append(checks, r(res, false))
	}

	return checks
}

// getResilienceResults handles registration and health checks for circuit breakers.
func getResilienceResults(cfg *config.Config, r func(Result, bool) Result) []Result {
	var results []Result

	// Proactively register configured breakers so they show up in the report
	for name := range cfg.Resilience.CircuitBreakers {
		if resilience.Get(name) == nil {
			maxFail, window, timeout := cfg.Breaker(name)
			resilience.New(name, maxFail, window, timeout)
		}
	}

	resResults := checkResilience()
	for _, res := range resResults {
		results = append(results, r(res, false))
	}

	// Check for old-format circuit breaker durations (C-138)
	for name, bc := range cfg.Resilience.CircuitBreakers {
		if bc.Window == "" || bc.Timeout == "" {
			results = append(results, Result{
				Name:        "breaker migration: " + name,
				OK:          false,
				Detail:      "duration fields are empty; migrate to string format (e.g. \"60s\")",
				Remediation: "Update Resilience.CircuitBreakers in config.json to use string durations.",
				Critical:    false,
			})
		}
	}

	return results
}

func checkStorageRoot(cfg *config.Config) Result {
	root := cfg.StorageRoot()
	info, err := os.Stat(root)
	if err != nil {
		return Result{
			Name:        "storage root",
			OK:          false,
			Detail:      fmt.Sprintf("%s: %v", root, err),
			Remediation: "Create the storage directory or check GOBOT_STORAGE environment variable.",
		}
	}
	if !info.IsDir() {
		return Result{
			Name:        "storage root",
			OK:          false,
			Detail:      fmt.Sprintf("%s is not a directory", root),
			Remediation: "Ensure GOBOT_STORAGE points to a directory, not a file.",
		}
	}
	return Result{Name: "storage root", OK: true, Detail: root}
}

func checkWorkspace(cfg *config.Config) Result {
	ws := filepath.Join(cfg.StorageRoot(), "workspace")
	tmp, err := os.CreateTemp(ws, "gobot-doctor-*")
	if err != nil {
		return Result{
			Name:        "workspace writable",
			OK:          false,
			Detail:      fmt.Sprintf("%s: %v", ws, err),
			Remediation: "Ensure the workspace directory is writable by the current user.",
		}
	}
	_ = tmp.Close()
	_ = os.Remove(tmp.Name())
	return Result{Name: "workspace writable", OK: true, Detail: ws}
}

func checkLogs(cfg *config.Config) Result {
	logs := filepath.Join(cfg.StorageRoot(), "logs")
	if err := os.MkdirAll(logs, 0o755); err != nil {
		return Result{
			Name:        "logs directory",
			OK:          false,
			Detail:      fmt.Sprintf("%v", err),
			Remediation: "Create the logs directory or check parent directory permissions.",
		}
	}
	return Result{Name: "logs directory", OK: true, Detail: logs}
}

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

// checkGoogleToken reads secrets/google_token.json and reports the token expiry.
func checkGoogleToken(secretsRoot string) Result {
	return checkTokenFile("google token", filepath.Join(secretsRoot, "google_token.json"))
}

// checkGmailToken reads secrets/gmail/token.json and reports the token expiry.
func checkGmailToken(secretsRoot string) Result {
	return checkTokenFile("gmail token", filepath.Join(secretsRoot, "gmail", "token.json"))
}

// checkGoogleOAuthSecrets verifies that OAuth client secrets exist before reauth.
func checkGoogleOAuthSecrets(cfg *config.Config) Result {
	path := filepath.Join(cfg.SecretsRoot(), "client_secrets.json")
	if _, err := os.Stat(path); err != nil {
		if os.IsNotExist(err) {
			return Result{
				Name:        "google oauth secrets",
				OK:          false,
				Detail:      fmt.Sprintf("missing required file before gobot reauth: %s", path),
				Remediation: "Download client_secrets.json from Google Cloud Console and place it in the secrets directory.",
			}
		}
		return Result{
			Name:        "google oauth secrets",
			OK:          false,
			Detail:      fmt.Sprintf("unable to check %s: %v", path, err),
			Remediation: "Check permissions for the secrets directory and client_secrets.json.",
		}
	}
	return Result{
		Name:   "google oauth secrets",
		OK:     true,
		Detail: path,
	}
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
			return Result{
				Name:        name,
				OK:          false,
				Detail:      fmt.Sprintf("not found: %s", path),
				Remediation: "Run 'gobot reauth' to generate a new token.",
			}
		}
		return Result{
			Name:        name,
			OK:          false,
			Detail:      err.Error(),
			Remediation: "Check file permissions for the token file.",
		}
	}
	var tok tokenExpiry
	if err := json.Unmarshal(data, &tok); err != nil {
		return Result{
			Name:        name,
			OK:          false,
			Detail:      fmt.Sprintf("invalid JSON: %v", err),
			Remediation: "Delete the invalid token file and run 'gobot reauth'.",
		}
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
	rem := ""
	if !ok {
		rem = "Run 'gobot reauth' to refresh your expired session."
	}
	return Result{
		Name:        name,
		OK:          ok,
		Detail:      buildExpiredTokenDetail(tok.Expiry, hasRefresh),
		Remediation: rem,
	}
}

// checkJobsDir verifies the cron jobs directory exists and has .md job files.
func checkJobsDir(cfg *config.Config) Result {
	dir := filepath.Join(cfg.StorageRoot(), "workspace", "jobs")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return Result{
			Name:        "jobs directory",
			OK:          false,
			Detail:      fmt.Sprintf("%s: %v", dir, err),
			Remediation: "Create a 'jobs' directory inside your workspace.",
		}
	}
	count := 0
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(strings.ToLower(e.Name()), ".md") {
			count++
		}
	}
	if count == 0 {
		return Result{
			Name:        "jobs directory",
			OK:          true,
			Detail:      fmt.Sprintf("%s (no .md jobs)", dir),
			Remediation: "Add .md job files to the jobs directory to use cron features.",
		}
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
		rem := ""
		if state == "open" {
			ok = false
			rem = "The service is currently failing; wait for the circuit breaker to close or check the underlying service health."
		}
		results = append(results, Result{
			Name:        "breaker: " + name,
			OK:          ok,
			Detail:      detail,
			Remediation: rem,
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

func checkAuthorization(cfg *config.Config) Result {
	mgr, err := agentctx.GetCheckpointManager(cfg.StorageRoot())
	if err != nil {
		return Result{
			Name:        "authorization",
			OK:          false,
			Detail:      fmt.Sprintf("failed to open checkpoint database: %v", err),
			Remediation: "Ensure the storage root is writable and the checkpoint database is not locked.",
		}
	}
	store, err := agentctx.NewPairingStore(mgr.DB())
	if err != nil {
		return Result{
			Name:        "authorization",
			OK:          false,
			Detail:      fmt.Sprintf("failed to initialize pairing store: %v", err),
			Remediation: "Check database integrity and permissions.",
		}
	}

	count, err := store.CountAuthorized()
	if err != nil {
		return Result{
			Name:        "authorization",
			OK:          false,
			Detail:      fmt.Sprintf("failed to query authorized users: %v", err),
			Remediation: "Check database integrity and permissions.",
		}
	}

	if count == 0 {
		return Result{
			Name:        "authorization",
			OK:          false,
			Detail:      "no users authorized — bot will drop all messages; run 'gobot authorize <chat-id>'",
			Remediation: "Run 'gobot authorize <chat-id>' to allow users to interact with the bot.",
		}
	}

	return Result{
		Name:   "authorization",
		OK:     true,
		Detail: fmt.Sprintf("%d user(s) authorized", count),
	}
}

// checkSecretsRoundtrip performs a Set→Get→Delete liveness check against the
// secrets store, proving that secrets written by the current user account can be
// decrypted by it. This catches account-mismatch failures (e.g. Task Scheduler
// running under a different account than the one that ran 'gobot authorize') at
// startup rather than mid-operation. It is advisory (non-critical).
//
// The check only runs on Windows, where DPAPI ties secrets to the user account.
// On Linux/macOS the AES-256 key file is portable, so the roundtrip is skipped
// and reported OK.
func checkSecretsRoundtrip(cfg *config.Config) Result {
	return checkSecretsRoundtripFor(runtime.GOOS, secrets.NewSecretsStore(cfg.StorageRoot()))
}

// checkSecretsRoundtripFor is the OS-injectable core of checkSecretsRoundtrip,
// kept separate so tests can exercise both the Windows and non-Windows paths
// against a fake store.
func checkSecretsRoundtripFor(goos string, store secrets.Roundtripper) Result {
	if goos != "windows" {
		return Result{
			Name:   "secrets roundtrip",
			OK:     true,
			Detail: "skipped (DPAPI is Windows-only)",
		}
	}
	if err := secrets.RoundtripTest(store); err != nil {
		return Result{
			Name:        "secrets roundtrip",
			OK:          false,
			Detail:      err.Error(),
			Remediation: "Ensure gobot runs under the same Windows account used for 'gobot authorize'/'gobot reauth'; re-run 'gobot reauth' if the account changed.",
		}
	}
	return Result{
		Name:   "secrets roundtrip",
		OK:     true,
		Detail: fmt.Sprintf("DPAPI Set→Get→Delete OK for user %q", secrets.CurrentUsername()),
	}
}

func checkSecurityStore(cfg *config.Config) Result {
	ws := filepath.Join(cfg.StorageRoot(), "workspace")
	secretsFile := filepath.Join(ws, "dpapi_secrets.json")

	_, err := os.Stat(secretsFile)
	exists := err == nil

	keyPath := secrets.KeyFilePath()
	if keyPath == "" { // Windows
		if !exists {
			return Result{Name: "security store", OK: true, Detail: "no vault found (optional)"}
		}
		return Result{Name: "security store", OK: true, Detail: "using Windows DPAPI"}
	}

	// Linux/macOS
	keyInfo, keyErr := os.Stat(keyPath)
	keyExists := keyErr == nil

	if exists && !keyExists {
		return Result{
			Name:        "security store",
			OK:          false,
			Detail:      fmt.Sprintf("vault exists but encryption key is missing: %s", keyPath),
			Remediation: "Restore the encryption key file from backup to access your secrets.",
		}
	}

	if !exists && !keyExists {
		return Result{Name: "security store", OK: true, Detail: "no vault or key found (optional)"}
	}

	if keyExists {
		mode := keyInfo.Mode().Perm()
		if mode != 0o600 {
			return Result{
				Name:        "security store",
				OK:          false,
				Detail:      fmt.Sprintf("insecure key permissions: %s (got %o, want 0600)", keyPath, mode),
				Remediation: fmt.Sprintf("Run 'chmod 600 %s' to secure your encryption key.", keyPath),
			}
		}
		return Result{Name: "security store", OK: true, Detail: "AES-256 vault active"}
	}

	return Result{Name: "security store", OK: true, Detail: "optional"}
}

// checkEncryptionKey verifies that the AES-256 encryption key file used by the
// secrets vault on Linux/macOS exists, is readable, and is the expected 32-byte
// length. On Windows the secrets package uses DPAPI instead of a key file, so
// the check returns OK with an informational detail. The check is advisory:
// failures surface a clear message instead of a generic crypto error at runtime.
func checkEncryptionKey() Result {
	keyPath := secrets.KeyFilePath()
	if keyPath == "" {
		return Result{Name: "encryption key", OK: true, Detail: "Windows DPAPI (no key file)"}
	}

	info, err := os.Stat(keyPath)
	if err != nil {
		if os.IsNotExist(err) {
			return Result{
				Name: "encryption key",
				OK:   false,
				Detail: fmt.Sprintf(
					"missing: %s — set GOBOT_ENCRYPTION_KEY_FILE to override the path; see docs/security.md for backup/restore",
					keyPath),
				Remediation: "Restore the encryption key file from backup or set GOBOT_ENCRYPTION_KEY_FILE.",
			}
		}
		return Result{
			Name:        "encryption key",
			OK:          false,
			Detail:      fmt.Sprintf("stat %s: %v", keyPath, err),
			Remediation: "Check file system permissions for the encryption key file.",
		}
	}
	if info.IsDir() {
		return Result{
			Name:        "encryption key",
			OK:          false,
			Detail:      fmt.Sprintf("expected file, found directory: %s", keyPath),
			Remediation: "Ensure GOBOT_ENCRYPTION_KEY_FILE points to a file, not a directory.",
		}
	}

	data, err := os.ReadFile(keyPath) // #nosec G304 - path comes from KeyFilePath, user-scoped config
	if err != nil {
		return Result{
			Name:        "encryption key",
			OK:          false,
			Detail:      fmt.Sprintf("unreadable %s: %v", keyPath, err),
			Remediation: "Ensure the current user has read permissions for the encryption key file.",
		}
	}
	if len(data) != 32 {
		return Result{
			Name:        "encryption key",
			OK:          false,
			Detail:      fmt.Sprintf("wrong length at %s: got %d byte(s), want 32 (AES-256)", keyPath, len(data)),
			Remediation: "Ensure the encryption key file contains exactly 32 bytes of random data.",
		}
	}
	return Result{Name: "encryption key", OK: true, Detail: fmt.Sprintf("AES-256 key present (32 bytes) at %s", keyPath)}
}

func checkPlaintextSecrets(cfg *config.Config) Result {
	var plaintext []string
	if cfg.Providers.Gemini.APIKey != "" {
		plaintext = append(plaintext, "Gemini")
	}
	if cfg.Channels.Telegram.Token != "" {
		plaintext = append(plaintext, "Telegram")
	}
	if cfg.Providers.Anthropic.APIKey != "" {
		plaintext = append(plaintext, "Anthropic")
	}
	if cfg.Providers.OpenAI.APIKey != "" {
		plaintext = append(plaintext, "OpenAI")
	}
	if cfg.Providers.OpenRouter.APIKey != "" {
		plaintext = append(plaintext, "OpenRouter")
	}
	if cfg.Providers.Google.APIKey != "" {
		plaintext = append(plaintext, "Google")
	}

	if len(plaintext) > 0 {
		return Result{
			Name: "plaintext secrets",
			OK:   false,
			Detail: fmt.Sprintf("keys for %s found in config.json; move to secure vault with 'gobot secrets set'",
				strings.Join(plaintext, ", ")),
			Remediation: "Use 'gobot secrets set' to move keys from config.json to the secure vault.",
		}
	}
	return Result{Name: "plaintext secrets", OK: true, Detail: "all keys stored securely (or missing)"}
}

func checkHITL(cfg *config.Config) Result {
	if !cfg.Channels.Telegram.HITL {
		return Result{
			Name:        "human-in-the-loop",
			OK:          false,
			Detail:      "HITL is disabled; high-risk tools will run without approval",
			Remediation: "Set channels.telegram.hitl=true in config.json for enhanced security.",
		}
	}
	return Result{Name: "human-in-the-loop", OK: true, Detail: "enabled for Telegram"}
}
