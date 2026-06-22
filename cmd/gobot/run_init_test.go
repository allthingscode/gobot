package main

import (
	"bytes"
	"context"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/allthingscode/gobot/internal/config"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestAutoInit(t *testing.T) {
	// Create a temporary directory for GOBOT_STORAGE
	tmpDir, err := os.MkdirTemp("", "gobot-test-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	// Set GOBOT_STORAGE to the temp dir
	t.Setenv("GOBOT_STORAGE", tmpDir)

	// Ensure GOBOT_HOME is also set to a temp dir to avoid messing with real config
	tmpHome, err := os.MkdirTemp("", "gobot-home-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpHome)
	t.Setenv("GOBOT_HOME", tmpHome)

	cfg, err := config.Load()
	require.NoError(t, err)

	// Verify workspace is incomplete
	assert.True(t, isWorkspaceIncomplete(cfg), "Workspace should be incomplete initially")

	// Call ensureWorkspace
	err = ensureWorkspace(io.Discard, cfg)
	require.NoError(t, err)

	// Verify workspace is now complete
	assert.False(t, isWorkspaceIncomplete(cfg), "Workspace should be complete after ensureWorkspace")

	// Check if directories exist
	dirs := []string{"sessions", "secrets", "memory", "logs"}
	for _, d := range dirs {
		path := cfg.WorkspacePath("", d)
		_, err := os.Stat(path)
		assert.NoError(t, err, "Directory %s should exist", path)
	}
}

func TestCmdRunAutoInit(t *testing.T) {
	// Setup temp home and storage
	tmpDir, err := os.MkdirTemp("", "gobot-run-autoinit-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	t.Setenv("GOBOT_STORAGE", tmpDir)

	tmpHome, err := os.MkdirTemp("", "gobot-home-run-autoinit-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpHome)
	t.Setenv("GOBOT_HOME", tmpHome)

	// We want to verify that running 'gobot run' initializes the workspace.
	// We'll use a context that we can cancel to prevent RunAgent from hanging,
	// but we expect it to fail early anyway because of missing config/keys.

	cmd := cmdRun()
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // Cancel immediately

	// Run the command. It might return an error because the context is canceled,
	// but we care about the side effect (workspace initialization).
	_ = cmd.ExecuteContext(ctx)

	// Verify that the workspace directories were created
	cfg, err := config.Load()
	require.NoError(t, err)

	assert.False(t, isWorkspaceIncomplete(cfg), "Workspace should be complete after running cmdRun")

	dirs := []string{"sessions", "secrets", "memory", "logs"}
	for _, d := range dirs {
		path := cfg.WorkspacePath("", d)
		_, err := os.Stat(path)
		assert.NoError(t, err, "Directory %s should have been created", path)
	}
}

func TestRunInit_PrintsResolvedPaths(t *testing.T) {
	tmpDir := t.TempDir()
	tmpHome := t.TempDir()
	t.Setenv("GOBOT_STORAGE", tmpDir)
	t.Setenv("GOBOT_HOME", tmpHome)

	var buf bytes.Buffer
	require.NoError(t, runInit(&buf, ""))

	out := buf.String()
	assert.Contains(t, out, "Resolved paths:")
	assert.Contains(t, out, "config: "+config.DefaultConfigPath())
	assert.Contains(t, out, "data:   "+tmpDir)
}

func TestRunInit_PrintsEncryptionKeyWarning(t *testing.T) {
	tmpDir := t.TempDir()
	tmpHome := t.TempDir()
	t.Setenv("GOBOT_STORAGE", tmpDir)
	t.Setenv("GOBOT_HOME", tmpHome)
	t.Setenv("GOBOT_ENCRYPTION_KEY_FILE", filepath.Join(tmpHome, "encryption.key"))

	var buf bytes.Buffer
	require.NoError(t, runInit(&buf, ""))

	out := buf.String()
	assert.Contains(t, out, "Initialized gobot workspace at")

	if runtime.GOOS == "windows" {
		assert.NotContains(t, out, "encryption key backup",
			"Windows uses DPAPI; no key file warning should be printed")
		return
	}
	assert.Contains(t, out, "encryption key backup")
	assert.Contains(t, out, filepath.Join(tmpHome, "encryption.key"))
	assert.Contains(t, out, "PERMANENTLY UNRECOVERABLE")
	assert.Contains(t, out, "GOBOT_ENCRYPTION_KEY_FILE")
}
