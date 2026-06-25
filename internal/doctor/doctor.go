// Package doctor implements the gobot health check (equivalent of strategic_doctor.py).
package doctor

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
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
		r(checkLivenessStaleness(cfg), false),
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
		r(checkVendorDir(), false),
		r(checkMemory(), false),
		r(checkCron(cfg), false),
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
