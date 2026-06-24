package doctor

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/secrets"
)

// tokenExpiry is a minimal struct for reading the expiry field and refresh_token from OAuth2 token files.
type tokenExpiry struct {
	Expiry       time.Time `json:"expiry"`
	RefreshToken string    `json:"refresh_token"`
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
