//nolint:testpackage // intentionally uses unexported helpers from main package
package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/config"
)

func TestBuildAwarenessContent(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{Strategic: config.StrategicConfig{StorageRoot: "/storage/root"}}
	content := buildAwarenessContent(cfg)
	checks := []string{
		"STRATEGIC AWARENESS",
		"/storage/root",
		"jobs",
		"YAML front-matter",
		"Daily Journal",
		"OPERATOR MANDATES",
	}
	for _, want := range checks {
		if !strings.Contains(content, want) {
			t.Errorf("buildAwarenessContent: missing %q", want)
		}
	}
}

func TestEnsureAwarenessFile(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	cfg := &config.Config{Strategic: config.StrategicConfig{StorageRoot: dir}}

	// First call: should create the file.
	ensureAwarenessFile(cfg)
	path := filepath.Join(dir, "workspace", "AWARENESS.md")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("file not created: %v", err)
	}
	if !strings.Contains(string(data), "STRATEGIC AWARENESS") {
		t.Error("file missing expected header")
	}

	// Second call: should not overwrite existing content.
	if err := os.WriteFile(path, []byte("custom content"), 0o600); err != nil {
		t.Fatal(err)
	}
	ensureAwarenessFile(cfg)
	data2, _ := os.ReadFile(path)
	if string(data2) != "custom content" {
		t.Error("ensureAwarenessFile overwrote existing file")
	}
}

// nolint:paralleltest // USERPROFILE is process-wide
func TestLoadPrivateFile(t *testing.T) {
	// Not t.Parallel() because we are messing with USERPROFILE

	t.Run("returns empty when file missing", func(t *testing.T) {
		cfg := &config.Config{Strategic: config.StrategicConfig{StorageRoot: t.TempDir()}}
		got := loadPrivateFile(cfg, "NON_EXISTENT.md")
		if got != "" {
			t.Errorf("expected empty string, got %q", got)
		}
	})

	t.Run("finds file in ~/.gobot (primary)", func(t *testing.T) {
		setupHome(t, "HOME.md", "home content")
		cfg := setupWorkspace(t, "", "")

		want := "home content"
		got := loadPrivateFile(cfg, "HOME.md")
		if got != want {
			t.Errorf("expected %q, got %q", want, got)
		}
	})

	t.Run("finds file in workspace (fallback)", func(t *testing.T) {
		cfg := setupWorkspace(t, "WORK.md", "workspace content")

		want := "workspace content"
		got := loadPrivateFile(cfg, "WORK.md")
		if got != want {
			t.Errorf("expected %q, got %q", want, got)
		}
	})

	t.Run("prioritizes ~/.gobot over workspace", func(t *testing.T) {
		setupHome(t, "BOTH.md", "home priority")
		cfg := setupWorkspace(t, "BOTH.md", "workspace content")

		homeWant := "home priority"
		got := loadPrivateFile(cfg, "BOTH.md")
		if got != homeWant {
			t.Errorf("expected %q, got %q", homeWant, got)
		}
	})
}

func setupHome(t *testing.T, filename, content string) string {
	t.Helper()
	tempHome := t.TempDir()
	t.Setenv("USERPROFILE", tempHome)
	t.Setenv("HOME", tempHome)
	dotGobot := filepath.Join(tempHome, ".gobot")
	if err := os.MkdirAll(dotGobot, 0o755); err != nil {
		t.Fatal(err)
	}
	if filename != "" {
		if err := os.WriteFile(filepath.Join(dotGobot, filename), []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return tempHome
}

func setupWorkspace(t *testing.T, filename, content string) *config.Config {
	t.Helper()
	dir := t.TempDir()
	cfg := &config.Config{Strategic: config.StrategicConfig{StorageRoot: dir}}
	workspaceDir := filepath.Join(dir, "workspace")
	if err := os.MkdirAll(workspaceDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if filename != "" {
		if err := os.WriteFile(filepath.Join(workspaceDir, filename), []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return cfg
}
