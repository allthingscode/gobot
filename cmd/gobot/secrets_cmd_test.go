package main

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

//nolint:paralleltest // uses global env/config
func TestCmdSecretsTest_Pass(t *testing.T) {
	tempDir := setupTestHome(t)
	_ = os.MkdirAll(filepath.Join(tempDir, "workspace"), 0o755)

	cmd := cmdSecretsTest()
	cmd.SetArgs([]string{})

	oldStdout := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe: %v", err)
	}
	os.Stdout = w
	if err := cmd.Execute(); err != nil {
		_ = w.Close()
		os.Stdout = oldStdout
		t.Fatalf("Execute: %v", err)
	}
	_ = w.Close()
	os.Stdout = oldStdout

	outBytes, err := io.ReadAll(r)
	if err != nil {
		t.Fatalf("ReadAll: %v", err)
	}
	out := string(outBytes)
	if !strings.Contains(out, "PASS") {
		t.Fatalf("expected PASS output, got: %q", out)
	}
	if !strings.Contains(out, "user") {
		t.Fatalf("expected username in output, got: %q", out)
	}
}

//nolint:paralleltest // uses global env/config
func TestCmdSecretsTest_FailsOnWriteError(t *testing.T) {
	tempDir := t.TempDir()
	storageFile := filepath.Join(tempDir, "not-a-dir")
	if err := os.WriteFile(storageFile, []byte("x"), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	t.Setenv("GOBOT_HOME", tempDir)
	t.Setenv("GOBOT_STORAGE", storageFile)

	cmd := cmdSecretsTest()
	cmd.SetArgs([]string{})

	err := cmd.Execute()
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !strings.Contains(err.Error(), "failed for user") {
		t.Fatalf("expected username context in error, got: %v", err)
	}
}
