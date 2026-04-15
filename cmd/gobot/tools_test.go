package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func createTestWorkspace(t *testing.T) string {
	t.Helper()
	tmpDir, err := os.MkdirTemp("", "gobot-test-workspace-*")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}
	t.Cleanup(func() {
		_ = os.RemoveAll(tmpDir)
	})

	testFile := "test.txt"
	testContent := "hello world"
	if err := os.WriteFile(filepath.Join(tmpDir, testFile), []byte(testContent), 0o600); err != nil {
		t.Fatalf("failed to write test file: %v", err)
	}

	subDir := "subdir"
	if err := os.Mkdir(filepath.Join(tmpDir, subDir), 0o700); err != nil {
		t.Fatalf("failed to create subdir: %v", err)
	}
	subFile := filepath.Join(subDir, "subtest.txt")
	if err := os.WriteFile(filepath.Join(tmpDir, subFile), []byte("subdir content"), 0o600); err != nil {
		t.Fatalf("failed to write subfile: %v", err)
	}
	return tmpDir
}

func TestReadTextFileTool_Sandbox(t *testing.T) {
	t.Parallel()
	tmpDir := createTestWorkspace(t)
	tool := &ReadTextFileTool{workspace: tmpDir}

	tests := []struct {
		name    string
		path    string
		want    string
		wantErr bool
		errMsg  string
	}{
		{
			name: "Valid relative path",
			path: "test.txt",
			want: "hello world",
		},
		{
			name: "Valid absolute path in workspace",
			path: filepath.Join(tmpDir, "test.txt"),
			want: "hello world",
		},
		{
			name: "Valid relative path in subdirectory",
			path: filepath.Join("subdir", "subtest.txt"),
			want: "subdir content",
		},
		{
			name:    "Empty path",
			path:    "",
			wantErr: true,
			errMsg:  "path is required",
		},
		{
			name:    "Traversal attempt - relative",
			path:    filepath.Join("..", "outside.txt"),
			wantErr: true,
			errMsg:  "is outside workspace",
		},
		{
			name:    "Traversal attempt - nested",
			path:    filepath.Join("subdir", "..", "..", "outside.txt"),
			wantErr: true,
			errMsg:  "is outside workspace",
		},
		{
			name:    "Absolute path outside workspace",
			path:    os.TempDir(),
			wantErr: true,
			errMsg:  "is outside workspace",
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got, err := tool.Execute(context.Background(), "session", "user", map[string]any{"path": tt.path})
			if (err != nil) != tt.wantErr {
				t.Errorf("Execute() error = %v, wantErr %v", err, tt.wantErr)
				return
			}
			if tt.wantErr {
				if !strings.Contains(err.Error(), tt.errMsg) {
					t.Errorf("Execute() error = %v, wantErrMsg %v", err, tt.errMsg)
				}
				return
			}
			if got != tt.want {
				t.Errorf("Execute() = %v, want %v", got, tt.want)
			}
		})
	}
}
