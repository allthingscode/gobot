//nolint:testpackage // requires unexported doctor internals for testing
package doctor

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/config"
)

// cfgWithRoot returns a Config with StorageRoot set to root.
func cfgWithRoot(root string) *config.Config {
	return &config.Config{
		Strategic: config.StrategicConfig{StorageRoot: root},
	}
}

// writeTokenJSON writes a minimal token file with the given expiry and optional refresh token to dir/filename.
func writeTokenJSON(t *testing.T, dir, filename string, expiry time.Time, refreshToken string) string {
	t.Helper()
	type tok struct {
		Token        string    `json:"token"`
		Expiry       time.Time `json:"expiry,omitempty"`
		RefreshToken string    `json:"refresh_token,omitempty"`
	}
	data, err := json.Marshal(tok{Token: "access_token", Expiry: expiry, RefreshToken: refreshToken}) //nolint:gosec // G117: test token, RefreshToken must be marshaled to write test fixture
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, filename)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// ── checkStorageRoot ──────────────────────────────────────────────────────────

func TestCheckStorageRoot_Exists(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	r := checkStorageRoot(cfgWithRoot(dir))
	if !r.OK {
		t.Errorf("expected OK=true for existing dir, got detail: %s", r.Detail)
	}
}

func TestCheckStorageRoot_Missing(t *testing.T) {
	t.Parallel()
	r := checkStorageRoot(cfgWithRoot(filepath.Join(t.TempDir(), "nonexistent")))
	if r.OK {
		t.Error("expected OK=false for missing directory")
	}
}

func TestCheckStorageRoot_IsFile(t *testing.T) {
	t.Parallel()
	f, err := os.CreateTemp(t.TempDir(), "not-a-dir-*")
	if err != nil {
		t.Fatal(err)
	}
	_ = f.Close()

	r := checkStorageRoot(cfgWithRoot(f.Name()))
	if r.OK {
		t.Error("expected OK=false when storage root is a file, not a directory")
	}
}

// ── checkWorkspace ────────────────────────────────────────────────────────────

func TestCheckWorkspace_Writable(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	ws := filepath.Join(root, "workspace")
	if err := os.MkdirAll(ws, 0o755); err != nil {
		t.Fatal(err)
	}

	r := checkWorkspace(cfgWithRoot(root))
	if !r.OK {
		t.Errorf("expected OK=true for writable workspace, got: %s", r.Detail)
	}
}

func TestCheckWorkspace_Missing(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	r := checkWorkspace(cfgWithRoot(root))
	if r.OK {
		t.Error("expected OK=false when workspace directory does not exist")
	}
}

// ── checkLogs ─────────────────────────────────────────────────────────────────

func TestCheckLogs_CreatesDir(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	r := checkLogs(cfgWithRoot(root))
	if !r.OK {
		t.Errorf("expected OK=true after creating logs dir, got: %s", r.Detail)
	}
	info, err := os.Stat(filepath.Join(root, "logs"))
	if err != nil {
		t.Fatalf("logs dir was not created: %v", err)
	}
	if !info.IsDir() {
		t.Error("expected logs to be a directory")
	}
}

func TestCheckLogs_AlreadyExists(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "logs"), 0o755); err != nil {
		t.Fatal(err)
	}
	r := checkLogs(cfgWithRoot(root))
	if !r.OK {
		t.Errorf("expected OK=true for existing logs dir, got: %s", r.Detail)
	}
}

func TestCheckLogs_BlockedByFile(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	blocker := filepath.Join(root, "logs")
	f, err := os.Create(blocker)
	if err != nil {
		t.Fatal(err)
	}
	_ = f.Close()

	r := checkLogs(cfgWithRoot(root))
	if r.OK {
		t.Error("expected OK=false when 'logs' path is a file, not a directory")
	}
}

// ── checkAPIKey ───────────────────────────────────────────────────────────────

func TestCheckAPIKey_FromConfig(t *testing.T) {
	t.Parallel()
	cfg := cfgWithRoot(t.TempDir())
	cfg.Providers.Gemini.APIKey = "test-api-key-1234"

	r := checkAPIKey(cfg)
	if !r.OK {
		t.Errorf("expected OK=true for key in config, got: %s", r.Detail)
	}
}

func TestCheckAPIKey_FromEnv(t *testing.T) {
	t.Setenv("GEMINI_API_KEY", "env-api-key-5678")

	r := checkAPIKey(cfgWithRoot(t.TempDir()))
	if !r.OK {
		t.Errorf("expected OK=true for key in env, got: %s", r.Detail)
	}
}

func TestCheckAPIKey_AnthropicKey(t *testing.T) {
	t.Setenv("ANTHROPIC_API_KEY", "sk-ant-test-key")

	r := checkAPIKey(cfgWithRoot(t.TempDir()))
	if !r.OK {
		t.Errorf("expected OK=true for Anthropic key, got: %s", r.Detail)
	}
}

func TestCheckAPIKey_OpenAIKey(t *testing.T) {
	t.Setenv("OPENAI_API_KEY", "sk-openai-test-key")

	r := checkAPIKey(cfgWithRoot(t.TempDir()))
	if !r.OK {
		t.Errorf("expected OK=true for OpenAI key, got: %s", r.Detail)
	}
}

func TestCheckAPIKey_Short(t *testing.T) {
	t.Parallel()
	cfg := cfgWithRoot(t.TempDir())
	cfg.Providers.Gemini.APIKey = "short"

	r := checkAPIKey(cfg)
	if !r.OK {
		t.Errorf("expected OK=true for short key, got: %s", r.Detail)
	}
}

func TestCheckAPIKey_Exact8(t *testing.T) {
	t.Parallel()
	cfg := cfgWithRoot(t.TempDir())
	cfg.Providers.Gemini.APIKey = "12345678"

	r := checkAPIKey(cfg)
	if !r.OK {
		t.Errorf("expected OK=true for 8-char key, got: %s", r.Detail)
	}
}

func TestCheckAPIKey_Missing(t *testing.T) {
	t.Setenv("GEMINI_API_KEY", "")
	t.Setenv("ANTHROPIC_API_KEY", "")
	t.Setenv("OPENAI_API_KEY", "")
	t.Setenv("OPENROUTER_API_KEY", "")

	r := checkAPIKey(cfgWithRoot(t.TempDir()))
	if r.OK {
		t.Error("expected OK=false when no API key is configured")
	}
}

// ── checkTelegram ─────────────────────────────────────────────────────────────

func TestCheckTelegram_TokenMissing(t *testing.T) {
	t.Parallel()
	r := checkTelegram("", nil)
	if r.OK {
		t.Error("expected OK=false for empty token")
	}
}

func TestCheckTelegram_NoProbe(t *testing.T) {
	t.Parallel()
	r := checkTelegram("bot:token", nil)
	if !r.OK {
		t.Errorf("expected OK=true (skipped) for present token with no probe, got: %s", r.Detail)
	}
}

func TestCheckTelegram_ProbeSuccess(t *testing.T) {
	t.Parallel()
	probe := func(_ string) (string, error) { return "@gobotprod", nil }
	r := checkTelegram("bot:token", probe)
	if !r.OK {
		t.Errorf("expected OK=true, got: %s", r.Detail)
	}
	if r.Detail != "@gobotprod" {
		t.Errorf("expected detail @gobotprod, got %q", r.Detail)
	}
}

func TestCheckTelegram_ProbeError(t *testing.T) {
	t.Parallel()
	probe := func(_ string) (string, error) { return "", errors.New("401 Unauthorized") }
	r := checkTelegram("bot:token", probe)
	if r.OK {
		t.Error("expected OK=false when probe returns error")
	}
}

// ── checkGeminiLive ───────────────────────────────────────────────────────────

func TestCheckGeminiLive_NoKey(t *testing.T) {
	t.Parallel()
	r := checkGeminiLive("", nil)
	if r.OK {
		t.Error("expected OK=false for empty api key")
	}
}

func TestCheckGeminiLive_NoProbe(t *testing.T) {
	t.Parallel()
	r := checkGeminiLive("AIzaSy-test", nil)
	if !r.OK {
		t.Errorf("expected OK=true (skipped) for present key with no probe, got: %s", r.Detail)
	}
}

func TestCheckGeminiLive_ProbeSuccess(t *testing.T) {
	t.Parallel()
	probe := func(_ string) error { return nil }
	r := checkGeminiLive("AIzaSy-test", probe)
	if !r.OK {
		t.Errorf("expected OK=true, got: %s", r.Detail)
	}
}

func TestCheckGeminiLive_ProbeError(t *testing.T) {
	t.Parallel()
	probe := func(_ string) error { return errors.New("quota exceeded") }
	r := checkGeminiLive("AIzaSy-test", probe)
	if r.OK {
		t.Error("expected OK=false when probe returns error")
	}
}

func TestCheckGoogleOAuthSecrets(t *testing.T) {
	t.Parallel()

	testCases := []struct {
		name        string
		createFile  bool
		expectedOK  bool
		detailParts []string
	}{
		{
			name:        "present",
			createFile:  true,
			expectedOK:  true,
			detailParts: []string{"client_secrets.json"},
		},
		{
			name:        "missing",
			createFile:  false,
			expectedOK:  false,
			detailParts: []string{"client_secrets.json", "before gobot reauth"},
		},
	}

	for _, tc := range testCases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			assertGoogleOAuthSecretsResult(t, tc.createFile, tc.expectedOK, tc.detailParts)
		})
	}
}

func assertGoogleOAuthSecretsResult(t *testing.T, createFile, expectedOK bool, detailParts []string) {
	t.Helper()

	root := t.TempDir()
	secretsDir := filepath.Join(root, "secrets")
	if err := os.MkdirAll(secretsDir, 0o755); err != nil {
		t.Fatalf("mkdir secrets dir: %v", err)
	}

	expectedPath := filepath.Join(secretsDir, "client_secrets.json")
	if createFile {
		if err := os.WriteFile(expectedPath, []byte(`{"installed":{}}`), 0o600); err != nil {
			t.Fatalf("write client secrets file: %v", err)
		}
	}

	result := checkGoogleOAuthSecrets(cfgWithRoot(root))
	if result.Name != "google oauth secrets" {
		t.Fatalf("expected check name %q, got %q", "google oauth secrets", result.Name)
	}
	if result.OK != expectedOK {
		t.Fatalf("expected OK=%v, got %v (detail=%q)", expectedOK, result.OK, result.Detail)
	}
	for _, part := range detailParts {
		if !strings.Contains(result.Detail, part) {
			t.Fatalf("expected detail %q to contain %q", result.Detail, part)
		}
	}
	if !strings.Contains(result.Detail, expectedPath) {
		t.Fatalf("expected detail to include resolved path %q, got %q", expectedPath, result.Detail)
	}
}

// ── checkTokenFile ────────────────────────────────────────────────────────────

func TestGetResults_GoogleOAuthSecretsIsNonCritical(t *testing.T) {
	t.Parallel()

	results := GetResults(cfgWithRoot(t.TempDir()), nil)
	found := false
	for _, result := range results {
		if result.Name == "google oauth secrets" {
			found = true
			if result.Critical {
				t.Fatalf("expected google oauth secrets check to be non-critical")
			}
		}
	}
	if !found {
		t.Fatalf("expected google oauth secrets check to be registered in GetResults")
	}
}

func TestCheckTokenFile_Missing(t *testing.T) {
	t.Parallel()
	r := checkTokenFile("test token", filepath.Join(t.TempDir(), "nonexistent.json"))
	if r.OK {
		t.Error("expected OK=false for missing token file")
	}
}

func TestCheckTokenFile_InvalidJSON(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	path := filepath.Join(dir, "bad.json")
	if err := os.WriteFile(path, []byte("not json"), 0o600); err != nil {
		t.Fatal(err)
	}

	r := checkTokenFile("test token", path)
	if r.OK {
		t.Error("expected OK=false for invalid JSON")
	}
}

func TestCheckTokenFile_NoExpiry(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	path := filepath.Join(dir, "tok.json")
	if err := os.WriteFile(path, []byte(`{"token":"abc"}`), 0o600); err != nil {
		t.Fatal(err)
	}

	r := checkTokenFile("test token", path)
	if !r.OK {
		t.Errorf("expected OK=true for token with no expiry, got: %s", r.Detail)
	}
}

func TestCheckTokenFile_Valid(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	writeTokenJSON(t, dir, "tok.json", time.Now().Add(30*24*time.Hour), "")

	r := checkTokenFile("test token", filepath.Join(dir, "tok.json"))
	if !r.OK {
		t.Errorf("expected OK=true for valid token, got: %s", r.Detail)
	}
}

func TestCheckTokenFile_ExpiredNoRefresh(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	writeTokenJSON(t, dir, "tok.json", time.Now().Add(-48*time.Hour), "")

	r := checkTokenFile("test token", filepath.Join(dir, "tok.json"))
	if r.OK {
		t.Error("expected OK=false for expired token with no refresh token")
	}
}

func TestCheckTokenFile_ExpiredWithRefresh(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	writeTokenJSON(t, dir, "tok.json", time.Now().Add(-48*time.Hour), "some_refresh_token")

	r := checkTokenFile("test token", filepath.Join(dir, "tok.json"))
	if !r.OK {
		t.Errorf("expected OK=true for expired token with refresh token, got: %s", r.Detail)
	}
}

// ── checkJobsDir ──────────────────────────────────────────────────────────────

func TestCheckJobsDir_Missing(t *testing.T) {
	t.Parallel()
	r := checkJobsDir(cfgWithRoot(t.TempDir()))
	if r.OK {
		t.Error("expected OK=false for missing jobs directory")
	}
}

func TestCheckJobsDir_EmptyDir(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	_ = os.MkdirAll(filepath.Join(root, "workspace", "jobs"), 0o755)

	r := checkJobsDir(cfgWithRoot(root))
	if !r.OK {
		t.Errorf("expected OK=true for empty jobs dir, got: %s", r.Detail)
	}
}

func TestCheckJobsDir_WithJobs(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	jobsDir := filepath.Join(root, "workspace", "jobs")
	_ = os.MkdirAll(jobsDir, 0o755)
	_ = os.WriteFile(filepath.Join(jobsDir, "morning.md"), []byte("---\nschedule: cron(0 8 * * *)\n---\nhello"), 0o600)
	_ = os.WriteFile(filepath.Join(jobsDir, "nightly.md"), []byte("---\nschedule: cron(0 3 * * *)\n---\nhello"), 0o600)

	r := checkJobsDir(cfgWithRoot(root))
	if !r.OK {
		t.Errorf("expected OK=true with .md jobs, got: %s", r.Detail)
	}
	if r.Detail == "" {
		t.Error("expected detail to mention job count")
	}
}

// ── Run ───────────────────────────────────────────────────────────────────────

func TestRun_AllChecksPass(t *testing.T) {
	root := t.TempDir()
	// Setup required subdirs for doctor
	if err := os.MkdirAll(filepath.Join(root, "workspace", "jobs"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "logs"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "secrets", "gmail"), 0o755); err != nil {
		t.Fatal(err)
	}

	// Mock valid token files
	writeTokenJSON(t, filepath.Join(root, "secrets"), "google_token.json", time.Now().Add(1*time.Hour), "")
	writeTokenJSON(t, filepath.Join(root, "secrets", "gmail"), "token.json", time.Now().Add(1*time.Hour), "")

	t.Setenv("GEMINI_API_KEY", "test-key-for-run-1234")

	cfg := cfgWithRoot(root)
	cfg.Channels.Telegram.Token = "123:test-token"

	// Use Run with nil probes (skips live checks)
	if err := Run(cfg, nil); err != nil {
		t.Errorf("expected Run to pass, got: %v", err)
	}
}

func TestRun_FailsOnBadStorageRoot(t *testing.T) {
	t.Setenv("GEMINI_API_KEY", "test-key-for-run-1234")

	cfg := cfgWithRoot(filepath.Join(t.TempDir(), "nonexistent"))
	if err := Run(cfg, nil); err == nil {
		t.Error("expected Run to return error for missing storage root")
	}
}

func TestDoctor_BreakerWarning(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	cfg.Resilience.CircuitBreakers = map[string]config.BreakerConfig{
		"old": {MaxFailures: 5, Window: "", Timeout: ""},
		"new": {MaxFailures: 5, Window: "1m", Timeout: "30s"},
	}

	results := GetResults(cfg, nil)
	foundWarning := false
	for _, r := range results {
		if r.Name == "breaker migration: old" {
			foundWarning = true
			if r.OK {
				t.Errorf("expected OK=false for old-format breaker warning")
			}
			if r.Critical {
				t.Errorf("expected Critical=false for old-format breaker warning")
			}
		}
		if r.Name == "breaker migration: new" {
			t.Errorf("did not expect warning for new-format breaker")
		}
	}

	if !foundWarning {
		t.Errorf("expected to find breaker migration warning for 'old'")
	}
}
