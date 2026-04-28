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
	// Create file in the expected workspace subdirectory
	workspaceDir := filepath.Join(tmpDir, "workspace")
	if err := os.MkdirAll(workspaceDir, 0o755); err != nil {
		t.Fatal(err)
	}
	filePath := filepath.Join(workspaceDir, "test.txt")
	if err := os.WriteFile(filePath, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}

	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = tmpDir
	tool := app.NewReadTextFileTool(cfg)
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
	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = tmpDir
	tool := app.NewReadTextFileTool(cfg)

	// Attempt to read something outside the sandbox
	_, err := tool.Execute(context.Background(), "sess", "user", map[string]any{
		"file_path": "../outside.txt",
	})
	if err == nil {
		t.Fatal("expected error for path outside sandbox, got nil")
	}
	if !strings.Contains(err.Error(), "is outside allowed roots") {
		t.Errorf("expected sandbox error, got: %v", err)
	}
}

func TestReadTextFileTool_Execute_ProjectRootFallback(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	
	// Create a workspace root and a project root
	workspaceDir := filepath.Join(tmpDir, "workspace")
	projectDir := filepath.Join(tmpDir, "project")
	if err := os.MkdirAll(workspaceDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(projectDir, 0o755); err != nil {
		t.Fatal(err)
	}

	// Create file ONLY in project root
	content := "Project Content"
	filePath := filepath.Join(projectDir, "project_file.txt")
	if err := os.WriteFile(filePath, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}

	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = tmpDir // WorkspacePath(userID) will use this + /workspace
	cfg.SetProjectRoot(projectDir)
	
	tool := app.NewReadTextFileTool(cfg)
	got, err := tool.Execute(context.Background(), "sess", "user", map[string]any{
		"file_path": "project_file.txt",
	})
	if err != nil {
		t.Fatalf("Execute failed: %v", err)
	}
	if got != content {
		t.Errorf("Execute got %q, want %q", got, content)
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
