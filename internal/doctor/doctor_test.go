//nolint:testpackage // requires unexported doctor internals for testing
package doctor

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
)

// TestMain runs the doctor suite, then fails if any checkpoint-manager handle
// was left open — i.e. a GetResults/Run/checkAuthorization test built its cfg
// without doctorTestCfg/registerCheckpointCleanup. On Windows an open
// checkpoints.db pins its temp dir and fails TempDir cleanup nondeterministically;
// this turns that latent leak into a deterministic failure on every platform.
func TestMain(m *testing.M) {
	code := m.Run()
	if code == 0 {
		if n := agentctx.CachedCheckpointManagerCountForTest(); n != 0 {
			fmt.Fprintf(os.Stderr, "doctor: %d checkpoint-manager handle(s) leaked after tests; build test cfgs via doctorTestCfg (or call registerCheckpointCleanup) so checkpoints.db is closed\n", n)
			code = 1
		}
	}
	os.Exit(code)
}

// cfgWithRoot returns a Config with StorageRoot set to root.
func cfgWithRoot(root string) *config.Config {
	return &config.Config{
		Runtime: config.RuntimeConfig{StorageRoot: root},
	}
}

// doctorTestCfg returns a Config rooted at a fresh temp dir and registers cleanup
// that closes the checkpoint-manager handle GetResults/Run cache for that root.
// GetCheckpointManager caches one open *sql.DB per StorageRoot for the process
// lifetime (correct in the live bot, where doctor shares the agent loop's handle);
// in tests each root is throwaway, so the handle must be closed or Windows cannot
// remove the temp dir. Any doctor test that reaches the checkpoint DB (GetResults,
// Run, checkAuthorization) must build its cfg here.
func doctorTestCfg(t *testing.T) *config.Config {
	t.Helper()
	cfg := cfgWithRoot(t.TempDir())
	registerCheckpointCleanup(t, cfg)
	return cfg
}

// registerCheckpointCleanup evicts the cached checkpoint-manager handle for cfg's
// StorageRoot when the test ends. Call it after the t.TempDir() the root derives
// from, so eviction runs before TempDir's RemoveAll (t.Cleanup is LIFO).
func registerCheckpointCleanup(t *testing.T, cfg *config.Config) {
	t.Helper()
	t.Cleanup(func() { agentctx.EvictCheckpointManagerForTest(cfg.StorageRoot()) })
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

	results := GetResults(doctorTestCfg(t), nil)
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
	registerCheckpointCleanup(t, cfg)

	// Use Run with nil probes (skips live checks)
	if err := Run(cfg, nil); err != nil {
		t.Errorf("expected Run to pass, got: %v", err)
	}
}

func TestRun_FailsOnBadStorageRoot(t *testing.T) {
	t.Setenv("GEMINI_API_KEY", "test-key-for-run-1234")

	cfg := cfgWithRoot(filepath.Join(t.TempDir(), "nonexistent"))
	registerCheckpointCleanup(t, cfg)
	if err := Run(cfg, nil); err == nil {
		t.Error("expected Run to return error for missing storage root")
	}
}

func TestDoctor_BreakerWarning(t *testing.T) {
	t.Parallel()
	cfg := doctorTestCfg(t)
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

// ── checkBrowser ─────────────────────────────────────────────────────────────

func TestCheckBrowser_Found(t *testing.T) {
	t.Parallel()

	mockLookPath := func(name string) (string, error) {
		return "mock-browser-path-" + name, nil
	}

	r := checkBrowser(config.BrowserConfig{Headless: true}, mockLookPath)
	if !r.OK {
		t.Errorf("expected OK=true when browser is found, got: %s", r.Detail)
	}
}

func TestCheckBrowser_NotFound(t *testing.T) {
	t.Parallel()

	mockLookPath := func(name string) (string, error) {
		return "", errors.New("not found")
	}

	r := checkBrowser(config.BrowserConfig{Headless: true}, mockLookPath)
	if r.OK {
		t.Error("expected OK=false when browser is not found")
	}
	if !strings.Contains(r.Detail, "not found") {
		t.Errorf("expected detail to mention not found, got: %s", r.Detail)
	}
}

func TestCheckBrowser_RemoteDebug(t *testing.T) {
	t.Parallel()

	r := checkBrowser(config.BrowserConfig{DebugPort: 9222}, exec.LookPath)
	if !r.OK {
		t.Errorf("expected OK=true for remote debug mode, got: %s", r.Detail)
	}
	if !strings.Contains(r.Detail, "9222") {
		t.Errorf("expected detail to mention port, got: %s", r.Detail)
	}
}

func TestCheckBrowser_NotConfigured(t *testing.T) {
	t.Parallel()

	r := checkBrowser(config.BrowserConfig{}, exec.LookPath)
	if r.OK {
		t.Error("expected OK=false when browser is not configured")
	}
	if !strings.Contains(r.Detail, "not configured") {
		t.Errorf("expected detail to mention not configured, got: %s", r.Detail)
	}
}

// ── checkAuthorization ───────────────────────────────────────────────────────

func TestCheckAuthorization(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	cfg := cfgWithRoot(root)
	registerCheckpointCleanup(t, cfg)

	// Case 1: Database initialized but no users
	r := checkAuthorization(cfg)
	if r.OK {
		t.Error("expected OK=false for zero authorized users")
	}
	if !strings.Contains(r.Detail, "no users authorized") {
		t.Errorf("expected detail to mention no users authorized, got: %s", r.Detail)
	}

	// Case 2: One user authorized
	mgr, err := agentctx.GetCheckpointManager(root)
	if err != nil {
		t.Fatalf("failed to get checkpoint manager: %v", err)
	}
	store, err := agentctx.NewPairingStore(mgr.DB())
	if err != nil {
		t.Fatalf("failed to create pairing store: %v", err)
	}
	if err := store.AuthorizeByChatID(12345, "test"); err != nil {
		t.Fatalf("failed to authorize user: %v", err)
	}

	r = checkAuthorization(cfg)
	if !r.OK {
		t.Errorf("expected OK=true for 1 authorized user, got: %s", r.Detail)
	}
	if !strings.Contains(r.Detail, "1 user(s) authorized") {
		t.Errorf("expected detail to mention 1 user authorized, got: %s", r.Detail)
	}
}

// ── checkSecurityStore ────────────────────────────────────────────────────────

func TestCheckSecurityStore(t *testing.T) {
	root := t.TempDir()
	cfg := cfgWithRoot(root)

	// Case 1: No vault
	r := checkSecurityStore(cfg)
	if !r.OK {
		t.Errorf("expected OK=true for no vault, got: %s", r.Detail)
	}

	// Case 2: Vault exists — point key path to a temp file so Linux/macOS CI
	// doesn't look at the real ~/.config/gobot/encryption.key.
	keyFile := filepath.Join(root, "encryption.key")
	if err := os.WriteFile(keyFile, make([]byte, 32), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GOBOT_ENCRYPTION_KEY_FILE", keyFile)

	ws := filepath.Join(root, "workspace")
	if err := os.MkdirAll(ws, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(ws, "dpapi_secrets.json"), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}

	r = checkSecurityStore(cfg)
	if !r.OK {
		t.Errorf("expected OK=true for vault exists, got: %s", r.Detail)
	}
}

// ── checkPlaintextSecrets ─────────────────────────────────────────────────────

func TestCheckPlaintextSecrets(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name     string
		cfg      *config.Config
		wantOK   bool
		contains string
	}{
		{
			name:   "all secure",
			cfg:    &config.Config{},
			wantOK: true,
		},
		{
			name: "gemini plaintext",
			cfg: &config.Config{
				Providers: config.ProvidersConfig{
					Gemini: config.GeminiConfig{APIKey: "sk-123"},
				},
			},
			wantOK:   false,
			contains: "Gemini",
		},
		{
			name: "multiple plaintext",
			cfg: &config.Config{
				Providers: config.ProvidersConfig{
					Gemini:     config.GeminiConfig{APIKey: "sk-123"},
					Google:     config.GoogleConfig{APIKey: "google-123"},
					Anthropic:  config.AnthropicConfig{APIKey: "ant-123"},
					OpenAI:     config.OpenAIConfig{APIKey: "oa-123"},
					OpenRouter: config.OpenAIConfig{APIKey: "or-123"},
				},
				Channels: config.ChannelsConfig{
					Telegram: config.TelegramConfig{Token: "bot-token"},
				},
			},
			wantOK:   false,
			contains: "Gemini, Telegram, Anthropic, OpenAI, OpenRouter, Google",
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			r := checkPlaintextSecrets(tt.cfg)
			if r.OK != tt.wantOK {
				t.Errorf("got OK=%v, want %v", r.OK, tt.wantOK)
			}
			if tt.contains != "" && !strings.Contains(r.Detail, tt.contains) {
				t.Errorf("expected detail to contain %q, got: %s", tt.contains, r.Detail)
			}
		})
	}
}

// ── checkHITL ─────────────────────────────────────────────────────────────────

func TestCheckHITL(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name   string
		cfg    *config.Config
		wantOK bool
	}{
		{
			name: "enabled",
			cfg: &config.Config{
				Channels: config.ChannelsConfig{
					Telegram: config.TelegramConfig{HITL: true},
				},
			},
			wantOK: true,
		},
		{
			name: "disabled",
			cfg: &config.Config{
				Channels: config.ChannelsConfig{
					Telegram: config.TelegramConfig{HITL: false},
				},
			},
			wantOK: false,
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			r := checkHITL(tt.cfg)
			if r.OK != tt.wantOK {
				t.Errorf("got OK=%v, want %v", r.OK, tt.wantOK)
			}
		})
	}
}

// ── checkEncryptionKey ───────────────────────────────────────────────────────

const goosWindows = "windows"

func TestCheckEncryptionKey_WindowsSkip(t *testing.T) {
	t.Parallel()
	if runtime.GOOS != goosWindows {
		t.Skip("Windows-only: DPAPI path used instead of key file")
	}
	r := checkEncryptionKey()
	if !r.OK {
		t.Errorf("expected OK=true on Windows, got detail: %s", r.Detail)
	}
	if !strings.Contains(r.Detail, "DPAPI") {
		t.Errorf("expected DPAPI in detail, got: %s", r.Detail)
	}
}

func TestCheckEncryptionKey_Missing(t *testing.T) {
	if runtime.GOOS == goosWindows {
		t.Skip("non-Windows-only: Windows uses DPAPI")
	}
	dir := t.TempDir()
	t.Setenv("GOBOT_ENCRYPTION_KEY_FILE", filepath.Join(dir, "missing.key"))

	r := checkEncryptionKey()
	if r.OK {
		t.Errorf("expected OK=false when key file missing, got: %+v", r)
	}
	if !strings.Contains(r.Detail, "missing") {
		t.Errorf("expected 'missing' in detail, got: %s", r.Detail)
	}
	if !strings.Contains(r.Detail, "GOBOT_ENCRYPTION_KEY_FILE") {
		t.Errorf("expected env var hint in detail, got: %s", r.Detail)
	}
	if !strings.Contains(r.Detail, "docs/security.md") {
		t.Errorf("expected docs reference in detail, got: %s", r.Detail)
	}
}

func TestCheckEncryptionKey_WrongLength(t *testing.T) {
	if runtime.GOOS == goosWindows {
		t.Skip("non-Windows-only: Windows uses DPAPI")
	}
	dir := t.TempDir()
	keyPath := filepath.Join(dir, "encryption.key")
	if err := os.WriteFile(keyPath, make([]byte, 16), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GOBOT_ENCRYPTION_KEY_FILE", keyPath)

	r := checkEncryptionKey()
	if r.OK {
		t.Errorf("expected OK=false for 16-byte key, got: %+v", r)
	}
	if !strings.Contains(r.Detail, "wrong length") {
		t.Errorf("expected 'wrong length' in detail, got: %s", r.Detail)
	}
}

func TestCheckEncryptionKey_Valid(t *testing.T) {
	if runtime.GOOS == goosWindows {
		t.Skip("non-Windows-only: Windows uses DPAPI")
	}
	dir := t.TempDir()
	keyPath := filepath.Join(dir, "encryption.key")
	if err := os.WriteFile(keyPath, make([]byte, 32), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GOBOT_ENCRYPTION_KEY_FILE", keyPath)

	r := checkEncryptionKey()
	if !r.OK {
		t.Errorf("expected OK=true for valid 32-byte key, got: %+v", r)
	}
	if !strings.Contains(r.Detail, "AES-256") {
		t.Errorf("expected 'AES-256' in detail, got: %s", r.Detail)
	}
}

// ── checkSecretsRoundtrip ────────────────────────────────────────────────────

// fakeStore is an in-memory secrets.Roundtripper for exercising the roundtrip
// check without touching real DPAPI/AES storage.
type fakeStore struct {
	data      map[string]string
	setErr    error
	getErr    error
	overrideR string // if non-empty, Get returns this instead of the stored value
}

func newFakeStore() *fakeStore { return &fakeStore{data: map[string]string{}} }

func (f *fakeStore) Set(key, value string) error {
	if f.setErr != nil {
		return f.setErr
	}
	f.data[key] = value
	return nil
}

func (f *fakeStore) Get(key string) (string, error) {
	if f.getErr != nil {
		return "", f.getErr
	}
	if f.overrideR != "" {
		return f.overrideR, nil
	}
	return f.data[key], nil
}

func (f *fakeStore) Delete(key string) error {
	delete(f.data, key)
	return nil
}

func TestCheckSecretsRoundtrip_Success(t *testing.T) {
	t.Parallel()
	r := checkSecretsRoundtripFor("windows", newFakeStore())
	if !r.OK {
		t.Errorf("expected OK=true for successful roundtrip, got: %+v", r)
	}
	if r.Critical {
		t.Error("secrets roundtrip check must be advisory (non-critical)")
	}
	if !strings.Contains(r.Detail, "OK") {
		t.Errorf("expected success detail, got: %s", r.Detail)
	}
}

func TestCheckSecretsRoundtrip_WriteFail(t *testing.T) {
	t.Parallel()
	store := newFakeStore()
	store.setErr = errors.New("dpapi protect failed")
	r := checkSecretsRoundtripFor("windows", store)
	if r.OK {
		t.Errorf("expected OK=false on write failure, got: %+v", r)
	}
	if !strings.Contains(r.Detail, "write failed") {
		t.Errorf("expected 'write failed' in detail, got: %s", r.Detail)
	}
	if r.Remediation == "" {
		t.Error("expected a remediation on failure")
	}
}

func TestCheckSecretsRoundtrip_ReadFail(t *testing.T) {
	t.Parallel()
	store := newFakeStore()
	store.getErr = errors.New("dpapi unprotect failed")
	r := checkSecretsRoundtripFor("windows", store)
	if r.OK {
		t.Errorf("expected OK=false on read failure, got: %+v", r)
	}
	if !strings.Contains(r.Detail, "read failed") {
		t.Errorf("expected 'read failed' in detail, got: %s", r.Detail)
	}
	if !strings.Contains(r.Detail, "Task Scheduler") {
		t.Errorf("expected account-mismatch hint in detail, got: %s", r.Detail)
	}
}

func TestCheckSecretsRoundtrip_Mismatch(t *testing.T) {
	t.Parallel()
	store := newFakeStore()
	store.overrideR = "tampered-value"
	r := checkSecretsRoundtripFor("windows", store)
	if r.OK {
		t.Errorf("expected OK=false on readback mismatch, got: %+v", r)
	}
	if !strings.Contains(r.Detail, "mismatch") {
		t.Errorf("expected 'mismatch' in detail, got: %s", r.Detail)
	}
}

// ── checkLivenessStaleness ───────────────────────────────────────────────────

func cfgWithHeartbeat(root, interval string) *config.Config {
	cfg := cfgWithRoot(root)
	cfg.Heartbeat.Interval = interval
	return cfg
}

func TestCheckLivenessStaleness_Missing(t *testing.T) {
	t.Parallel()
	r := checkLivenessStaleness(cfgWithRoot(t.TempDir()))
	if !r.OK {
		t.Errorf("expected OK=true when LIVENESS file is absent (cold start), got: %+v", r)
	}
	if r.Critical {
		t.Error("liveness staleness check must be advisory (non-critical)")
	}
	if !strings.Contains(r.Detail, "cold start") {
		t.Errorf("expected cold-start detail, got: %s", r.Detail)
	}
}

func TestCheckLivenessStaleness_Fresh(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	path := filepath.Join(root, "LIVENESS")
	if err := os.WriteFile(path, []byte("ok\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	r := checkLivenessStaleness(cfgWithHeartbeat(root, "15m"))
	if !r.OK {
		t.Errorf("expected OK=true for fresh LIVENESS file, got: %+v", r)
	}
}

func TestCheckLivenessStaleness_Stale(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	path := filepath.Join(root, "LIVENESS")
	if err := os.WriteFile(path, []byte("ok\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	// With a 1m interval the threshold is 2m; set mtime 10m in the past.
	old := time.Now().Add(-10 * time.Minute)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatal(err)
	}

	r := checkLivenessStaleness(cfgWithHeartbeat(root, "1m"))
	if r.OK {
		t.Errorf("expected OK=false for stale LIVENESS file, got: %+v", r)
	}
	if r.Critical {
		t.Error("liveness staleness check must be advisory (non-critical)")
	}
	if !strings.Contains(r.Detail, "threshold") {
		t.Errorf("expected staleness detail to mention threshold, got: %s", r.Detail)
	}
	if r.Remediation == "" {
		t.Error("expected a remediation hint for a stale heartbeat")
	}
}

//nolint:paralleltest // mutates the package-global livenessStatFn seam; must not run concurrently with other liveness tests
func TestCheckLivenessStaleness_StatError(t *testing.T) {
	orig := livenessStatFn
	t.Cleanup(func() { livenessStatFn = orig })
	livenessStatFn = func(string) (os.FileInfo, error) {
		return nil, errors.New("permission denied")
	}

	r := checkLivenessStaleness(cfgWithRoot(t.TempDir()))
	if r.OK {
		t.Errorf("expected OK=false when stat returns a non-NotExist error, got: %+v", r)
	}
	if r.Critical {
		t.Error("liveness staleness check must be advisory (non-critical)")
	}
	if r.Remediation == "" {
		t.Error("expected a remediation hint when LIVENESS cannot be read")
	}
}

func TestGetResults_LivenessStalenessIsNonCritical(t *testing.T) {
	t.Parallel()

	results := GetResults(doctorTestCfg(t), nil)
	found := false
	for _, result := range results {
		if result.Name == "liveness staleness" {
			found = true
			if result.Critical {
				t.Fatal("expected liveness staleness check to be non-critical")
			}
		}
	}
	if !found {
		t.Fatal("expected liveness staleness check to be registered in GetResults")
	}
}

// ── checkVendorDir (B-001 footgun guard) ──────────────────────────────────────

//nolint:paralleltest // mutates the package-global vendorDirFn seam; must not run concurrently with other vendor tests
func TestCheckVendorDir_AbsentIsOK(t *testing.T) {
	orig := vendorDirFn
	defer func() { vendorDirFn = orig }()
	vendorDirFn = func() string { return filepath.Join(t.TempDir(), "vendor") }

	r := checkVendorDir()
	if !r.OK {
		t.Errorf("expected OK=true when no vendor/ dir, got detail: %s", r.Detail)
	}
}

//nolint:paralleltest // mutates the package-global vendorDirFn seam; must not run concurrently with other vendor tests
func TestCheckVendorDir_PresentWarns(t *testing.T) {
	orig := vendorDirFn
	defer func() { vendorDirFn = orig }()
	vendorPath := filepath.Join(t.TempDir(), "vendor")
	if err := os.MkdirAll(vendorPath, 0o755); err != nil {
		t.Fatal(err)
	}
	vendorDirFn = func() string { return vendorPath }

	r := checkVendorDir()
	if r.OK {
		t.Error("expected OK=false when a vendor/ directory is present")
	}
	if r.Remediation == "" {
		t.Error("expected a remediation hint when vendor/ is present")
	}
	if !strings.Contains(r.Detail, "shadows go.mod") {
		t.Errorf("expected detail to mention shadowing go.mod, got: %s", r.Detail)
	}
}

//nolint:paralleltest // mutates the package-global vendorDirFn seam; must not run concurrently with other vendor tests
func TestCheckVendorDir_FileNotDirIsOK(t *testing.T) {
	orig := vendorDirFn
	defer func() { vendorDirFn = orig }()
	vendorPath := filepath.Join(t.TempDir(), "vendor")
	if err := os.WriteFile(vendorPath, []byte("not a dir"), 0o600); err != nil {
		t.Fatal(err)
	}
	vendorDirFn = func() string { return vendorPath }

	r := checkVendorDir()
	if !r.OK {
		t.Errorf("expected OK=true when vendor is a file, got detail: %s", r.Detail)
	}
}

func TestCheckVendorDir_IsNonCritical(t *testing.T) {
	t.Parallel()

	results := GetResults(doctorTestCfg(t), nil)
	found := false
	for _, result := range results {
		if result.Name == "vendor policy" {
			found = true
			if result.Critical {
				t.Fatal("expected vendor policy check to be non-critical")
			}
		}
	}
	if !found {
		t.Fatal("expected vendor policy check to be registered in GetResults")
	}
}

func TestGetResults_IncludesStorageSizes(t *testing.T) {
	t.Parallel()
	results := GetResults(doctorTestCfg(t), nil)
	for i := range results {
		if results[i].Name == "storage sizes" {
			if results[i].Critical {
				t.Error("storage sizes result must be non-critical")
			}
			return
		}
	}
	t.Fatal("GetResults did not include a 'storage sizes' result")
}

func TestConcurrencyResult_LockStaleness(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 7, 14, 12, 0, 0, 0, time.UTC)

	tests := []struct {
		name              string
		status            agent.LockStatus
		wantOK            bool
		wantDetailParts   []string
		wantRemediation   bool
		notWantDetailPart string
	}{
		{
			name:   "unlocked historical contention",
			status: agent.LockStatus{ContentionCount: 2, MaxWaitTime: 150 * time.Millisecond, TotalHoldTime: 3 * time.Second},
			wantOK: true,
			wantDetailParts: []string{
				"locked: false",
				"held: n/a",
				"contention: 2",
				"max_wait: 150ms",
				"total_hold: 3s",
			},
		},
		{
			name:   "currently held below threshold",
			status: agent.LockStatus{IsLocked: true, AcquiredAt: now.Add(-30 * time.Second), ContentionCount: 1},
			wantOK: true,
			wantDetailParts: []string{
				"locked: true",
				"held: 30s",
				"contention: 1",
			},
		},
		{
			name:   "currently held above threshold",
			status: agent.LockStatus{IsLocked: true, AcquiredAt: now.Add(-2 * time.Minute), ContentionCount: 3, MaxWaitTime: time.Second, TotalHoldTime: 4 * time.Second},
			wantOK: false,
			wantDetailParts: []string{
				"locked: true",
				"held: 2m0s",
				"contention: 3",
				"max_wait: 1s",
				"total_hold: 4s",
			},
			wantRemediation:   true,
			notWantDetailPart: "goroutine",
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			result := concurrencyResult("session-alpha", tt.status, now)
			assertConcurrencyResult(t, result, tt.wantOK, tt.wantDetailParts, tt.wantRemediation, tt.notWantDetailPart)
		})
	}
}

func assertConcurrencyResult(t *testing.T, result Result, wantOK bool, wantDetailParts []string, wantRemediation bool, notWantDetailPart string) {
	t.Helper()
	if result.Name != "lock: session-alpha" {
		t.Fatalf("Name = %q, want lock: session-alpha", result.Name)
	}
	if result.OK != wantOK {
		t.Fatalf("OK = %v, want %v; detail=%q", result.OK, wantOK, result.Detail)
	}
	if result.Critical {
		t.Fatal("stale lock warning must remain non-critical")
	}
	for _, want := range wantDetailParts {
		if !strings.Contains(result.Detail, want) {
			t.Fatalf("Detail missing %q: %s", want, result.Detail)
		}
	}
	if wantRemediation && result.Remediation == "" {
		t.Fatal("expected remediation for stale lock")
	}
	if notWantDetailPart != "" && strings.Contains(result.Detail, notWantDetailPart) {
		t.Fatalf("Detail should not contain %q: %s", notWantDetailPart, result.Detail)
	}
}

func TestCheckSecretsRoundtrip_NonWindowsSkip(t *testing.T) {
	t.Parallel()
	// A failing store must NOT cause a failure on non-Windows: the check is skipped.
	store := newFakeStore()
	store.setErr = errors.New("should never be called")
	for _, goos := range []string{"linux", "darwin"} {
		r := checkSecretsRoundtripFor(goos, store)
		if !r.OK {
			t.Errorf("[%s] expected OK=true (skipped), got: %+v", goos, r)
		}
		if !strings.Contains(r.Detail, "skipped") {
			t.Errorf("[%s] expected 'skipped' in detail, got: %s", goos, r.Detail)
		}
	}
}
