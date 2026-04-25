//nolint:testpackage // intentionally uses unexported helpers from main package
package app

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/config"
)

func TestBuildAwarenessContent(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	// StorageRoot defaults to ~/gobot_data or similar, but we can set it via Strategic.StorageRoot
	tmpDir := t.TempDir()
	cfg.Strategic.StorageRoot = tmpDir

	got := buildAwarenessContent(cfg)

	// Check for key elements in the generated content
	expectedElements := []string{
		"# STRATEGIC AWARENESS",
		"Workspace Root:** " + tmpDir,
		"Task Directory:** `" + filepath.Join(tmpDir, "workspace", "jobs") + "`",
		"journal",
		"checkpoints.db",
		"Zero Drive-Root Writes",
	}

	for _, element := range expectedElements {
		if !strings.Contains(got, element) {
			t.Errorf("buildAwarenessContent() missing element: %q", element)
		}
	}
}

func TestEnsureAwarenessFile(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = tmpDir

	awarenessPath := cfg.WorkspacePath("", "AWARENESS.md")

	// Case 1: File does not exist, should be created
	EnsureAwarenessFile(cfg)
	if _, err := os.Stat(awarenessPath); os.IsNotExist(err) {
		t.Error("EnsureAwarenessFile() failed to create AWARENESS.md")
	}

	// Case 2: File exists, should not be overwritten (we'll check this by modifying it)
	originalContent := "already exists"
	if err := os.WriteFile(awarenessPath, []byte(originalContent), 0o600); err != nil {
		t.Fatal(err)
	}

	EnsureAwarenessFile(cfg)
	data, err := os.ReadFile(awarenessPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != originalContent {
		t.Errorf("EnsureAwarenessFile() overwrote existing file: got %q, want %q", string(data), originalContent)
	}
}

//nolint:paralleltest // uses global state // mocking package-level variable
func TestLoadPrivateFile(t *testing.T) {
	origHome := userHomeDir
	defer func() { userHomeDir = origHome }()

	tmpHome := t.TempDir()
	userHomeDir = func() (string, error) {
		return tmpHome, nil
	}

	cfg := &config.Config{}
	tmpStorage := t.TempDir()
	cfg.Strategic.StorageRoot = tmpStorage

	filename := "TEST_FILE.md"
	content := "test content"

	// Case 1: File in ~/.gobot/
	dotGobotDir := filepath.Join(tmpHome, ".gobot")
	if err := os.MkdirAll(dotGobotDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dotGobotDir, filename), []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}

	got := loadPrivateFile(cfg, filename)
	if got != content {
		t.Errorf("loadPrivateFile() from ~/.gobot got %q, want %q", got, content)
	}

	// Case 2: File in workspace fallback
	os.RemoveAll(dotGobotDir)
	workspaceDir := filepath.Join(tmpStorage, "workspace")
	if err := os.MkdirAll(workspaceDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(workspaceDir, filename), []byte("workspace content"), 0o600); err != nil {
		t.Fatal(err)
	}

	got = loadPrivateFile(cfg, filename)
	if got != "workspace content" {
		t.Errorf("loadPrivateFile() from workspace got %q, want %q", got, "workspace content")
	}

	// Case 3: Not found
	got = loadPrivateFile(cfg, "NONEXISTENT.md")
	if got != "" {
		t.Errorf("loadPrivateFile() for nonexistent file got %q, want empty", got)
	}
}

//nolint:paralleltest // uses global state // mocking package-level variable
func TestLoadSystemPrompt(t *testing.T) {
	origHome := userHomeDir
	defer func() { userHomeDir = origHome }()
	tmpHome := t.TempDir()
	userHomeDir = func() (string, error) { return tmpHome, nil }

	tmpStorage := t.TempDir()
	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = tmpStorage

	// Create SOUL.md in ~/.gobot
	dotGobotDir := filepath.Join(tmpHome, ".gobot")
	if err := os.MkdirAll(dotGobotDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dotGobotDir, "SOUL.md"), []byte("soul content"), 0o600); err != nil {
		t.Fatal(err)
	}

	// Create AWARENESS.md in workspace
	workspaceDir := filepath.Join(tmpStorage, "workspace")
	if err := os.MkdirAll(workspaceDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(workspaceDir, "AWARENESS.md"), []byte("awareness content"), 0o600); err != nil {
		t.Fatal(err)
	}

	// Create a journal entry for today
	journalDir := filepath.Join(workspaceDir, "journal")
	if err := os.MkdirAll(journalDir, 0o755); err != nil {
		t.Fatal(err)
	}
	today := time.Now().Format("2006-01-02")
	if err := os.WriteFile(filepath.Join(journalDir, today+".md"), []byte("journal content"), 0o600); err != nil {
		t.Fatal(err)
	}

	got := LoadSystemPrompt(cfg)

	// Check if all parts are present
	if !strings.Contains(got, "soul content") {
		t.Error("LoadSystemPrompt() missing soul content")
	}
	if !strings.Contains(got, "awareness content") {
		t.Error("LoadSystemPrompt() missing awareness content")
	}
	if !strings.Contains(got, "journal content") {
		t.Error("LoadSystemPrompt() missing journal content")
	}
}

func TestLoadScheduleContext(t *testing.T) {
	t.Parallel()
	// Case: empty secrets root (will fail to load google services)
	got := loadScheduleContext("")
	if got != "" {
		t.Errorf("expected empty context for empty secrets root, got %q", got)
	}
}
