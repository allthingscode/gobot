package app_test

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/app"
	"github.com/allthingscode/gobot/internal/config"
)

func TestReadTextFileTool_Name(t *testing.T) {
	t.Parallel()
	tool := &app.ReadTextFileTool{}
	if tool.Name() != "read_text_file" {
		t.Errorf("Name() = %q, want 'read_text_file'", tool.Name())
	}
}

func TestReadTextFileTool_Declaration(t *testing.T) {
	t.Parallel()
	tool := &app.ReadTextFileTool{}
	decl := tool.Declaration()
	if decl.Name != "read_text_file" {
		t.Errorf("Declaration.Name = %q, want 'read_text_file'", decl.Name)
	}
}

func TestReadTextFileTool_Execute_Success(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	content := "Hello, Go!"
	filePath := filepath.Join(tmpDir, "test.txt")
	if err := os.WriteFile(filePath, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}

	tool := app.NewReadTextFileTool(tmpDir)
	got, err := tool.Execute(context.Background(), "sess", "user", map[string]any{
		"file_path": "test.txt",
	})
	if err != nil {
		t.Fatalf("Execute failed: %v", err)
	}
	if got != content {
		t.Errorf("Execute got %q, want %q", got, content)
	}
}

func TestReadTextFileTool_Execute_SandboxEscaping(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	tool := app.NewReadTextFileTool(tmpDir)

	// Attempt to read something outside the sandbox
	_, err := tool.Execute(context.Background(), "sess", "user", map[string]any{
		"file_path": "../outside.txt",
	})
	if err == nil {
		t.Fatal("expected error for path outside sandbox, got nil")
	}
	if !strings.Contains(err.Error(), "is outside workspace") {
		t.Errorf("expected sandbox error, got: %v", err)
	}
}

func TestRegisterTools_App(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	prov := &app.MockProvider{}
	tools := app.RegisterTools(cfg, prov, "model", nil, nil, nil, nil, nil)
	if len(tools) == 0 {
		t.Error("RegisterTools returned zero tools")
	}
}
