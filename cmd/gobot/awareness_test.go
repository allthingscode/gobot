//nolint:testpackage // intentionally uses unexported helpers from main package
package main

import (
	"os"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/app"
	"github.com/allthingscode/gobot/internal/config"
)

func TestEnsureAwarenessFile(t *testing.T) {
	// t.Parallel() disabled because of t.Setenv
	tmpDir := t.TempDir()
	// Override storage root via environment so WorkspacePath follows it.
	t.Setenv("GOBOT_STORAGE", tmpDir)

	// Explicitly reload config to ensure it sees the env var
	cfg, _ := config.Load()
	awarenessPath := cfg.WorkspacePath("", "AWARENESS.md")

	// Ensure no file exists from previous run (though TempDir should be clean)
	_ = os.Remove(awarenessPath)

	// 1. Initial creation
	app.EnsureAwarenessFile(cfg)
	if _, err := os.Stat(awarenessPath); os.IsNotExist(err) {
		t.Fatalf("EnsureAwarenessFile did not create AWARENESS.md at %s", awarenessPath)
	}

	data, err := os.ReadFile(awarenessPath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "# STRATEGIC AWARENESS") {
		t.Errorf("AWARENESS.md missing header, got:\n%s", string(data))
	}

	// 2. No-op when exists (don't overwrite custom content)
	custom := "custom content"
	if err := os.WriteFile(awarenessPath, []byte(custom), 0o600); err != nil {
		t.Fatal(err)
	}
	// Call it again - it should NOT overwrite
	app.EnsureAwarenessFile(cfg)
	data, _ = os.ReadFile(awarenessPath)
	if string(data) != custom {
		t.Errorf("EnsureAwarenessFile should NOT have overwritten existing file, but it did. Got:\n%s", string(data))
	}
}
