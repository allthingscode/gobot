package doctor

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/allthingscode/gobot/internal/config"
)

// cfgWithRoot returns a Config with StorageRoot set to root.
func cfgWithRoot(root string) *config.Config {
	return &config.Config{
		Strategic: config.StrategicConfig{StorageRoot: root},
	}
}

// ── checkStorageRoot ──────────────────────────────────────────────────────────

func TestCheckStorageRoot_Exists(t *testing.T) {
	dir := t.TempDir()
	r := checkStorageRoot(cfgWithRoot(dir))
	if !r.ok {
		t.Errorf("expected ok=true for existing dir, got detail: %s", r.detail)
	}
}

func TestCheckStorageRoot_Missing(t *testing.T) {
	r := checkStorageRoot(cfgWithRoot(filepath.Join(t.TempDir(), "nonexistent")))
	if r.ok {
		t.Error("expected ok=false for missing directory")
	}
}

func TestCheckStorageRoot_IsFile(t *testing.T) {
	f, err := os.CreateTemp(t.TempDir(), "not-a-dir-*")
	if err != nil {
		t.Fatal(err)
	}
	f.Close()

	r := checkStorageRoot(cfgWithRoot(f.Name()))
	if r.ok {
		t.Error("expected ok=false when storage root is a file, not a directory")
	}
}

// ── checkWorkspace ────────────────────────────────────────────────────────────

func TestCheckWorkspace_Writable(t *testing.T) {
	root := t.TempDir()
	ws := filepath.Join(root, "workspace")
	if err := os.MkdirAll(ws, 0o755); err != nil {
		t.Fatal(err)
	}

	r := checkWorkspace(cfgWithRoot(root))
	if !r.ok {
		t.Errorf("expected ok=true for writable workspace, got: %s", r.detail)
	}
}

func TestCheckWorkspace_Missing(t *testing.T) {
	root := t.TempDir()
	// workspace subdir not created — CreateTemp inside it should fail
	r := checkWorkspace(cfgWithRoot(root))
	if r.ok {
		t.Error("expected ok=false when workspace directory does not exist")
	}
}

// ── checkLogs ─────────────────────────────────────────────────────────────────

func TestCheckLogs_CreatesDir(t *testing.T) {
	root := t.TempDir()
	// logs/ does not exist yet — checkLogs should create it
	r := checkLogs(cfgWithRoot(root))
	if !r.ok {
		t.Errorf("expected ok=true after creating logs dir, got: %s", r.detail)
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
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "logs"), 0o755); err != nil {
		t.Fatal(err)
	}
	r := checkLogs(cfgWithRoot(root))
	if !r.ok {
		t.Errorf("expected ok=true for existing logs dir, got: %s", r.detail)
	}
}

func TestCheckLogs_BlockedByFile(t *testing.T) {
	root := t.TempDir()
	// Create a regular file named "logs" — MkdirAll on that path must fail.
	blocker := filepath.Join(root, "logs")
	f, err := os.Create(blocker)
	if err != nil {
		t.Fatal(err)
	}
	f.Close()

	r := checkLogs(cfgWithRoot(root))
	if r.ok {
		t.Error("expected ok=false when 'logs' path is a file, not a directory")
	}
}

// ── checkAPIKey ───────────────────────────────────────────────────────────────

func TestCheckAPIKey_FromConfig(t *testing.T) {
	cfg := cfgWithRoot(t.TempDir())
	cfg.Providers.Gemini.APIKey = "test-api-key-1234"

	r := checkAPIKey(cfg)
	if !r.ok {
		t.Errorf("expected ok=true for key in config, got: %s", r.detail)
	}
}

func TestCheckAPIKey_FromEnv(t *testing.T) {
	t.Setenv("GOOGLE_API_KEY", "env-api-key-5678")

	r := checkAPIKey(cfgWithRoot(t.TempDir()))
	if !r.ok {
		t.Errorf("expected ok=true for key in env, got: %s", r.detail)
	}
}

func TestCheckAPIKey_Missing(t *testing.T) {
	// Ensure env var is unset for this test.
	t.Setenv("GOOGLE_API_KEY", "")

	r := checkAPIKey(cfgWithRoot(t.TempDir()))
	if r.ok {
		t.Error("expected ok=false when no API key is configured")
	}
}

// ── Run ───────────────────────────────────────────────────────────────────────

func TestRun_AllChecksPass(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "workspace"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GOOGLE_API_KEY", "test-key-for-run-1234")

	cfg := cfgWithRoot(root)
	if err := Run(cfg); err != nil {
		t.Errorf("expected Run to pass, got: %v", err)
	}
}

func TestRun_FailsOnBadStorageRoot(t *testing.T) {
	t.Setenv("GOOGLE_API_KEY", "test-key-for-run-1234")

	cfg := cfgWithRoot(filepath.Join(t.TempDir(), "nonexistent"))
	if err := Run(cfg); err == nil {
		t.Error("expected Run to return error for missing storage root")
	}
}
