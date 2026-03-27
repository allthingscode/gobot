package infra

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestResolveMediaPath(t *testing.T) {
	tmpDir := t.TempDir()

	tests := []struct {
		name        string
		storageRoot string
		channel     string
		wantSuffix  string
	}{
		{
			name:        "default storage root",
			storageRoot: "",
			channel:     "",
			wantSuffix:  filepath.Join("workspace", "media"),
		},
		{
			name:        "custom storage root",
			storageRoot: tmpDir,
			channel:     "",
			wantSuffix:  "media", // Joins with tmpDir/workspace/media
		},
		{
			name:        "custom storage root and channel",
			storageRoot: tmpDir,
			channel:     "telegram",
			wantSuffix:  "telegram", // Joins with tmpDir/workspace/media/telegram
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := ResolveMediaPath(tt.storageRoot, tt.channel)
			if tt.storageRoot != "" {
				if !strings.Contains(got, tt.storageRoot) {
					t.Errorf("ResolveMediaPath() = %v, must contain %v", got, tt.storageRoot)
				}
			}
			if !strings.HasSuffix(got, tt.wantSuffix) {
				t.Errorf("ResolveMediaPath() = %v, must end with %v", got, tt.wantSuffix)
			}

			// Verify directory was created
			if info, err := os.Stat(got); err != nil || !info.IsDir() {
				t.Errorf("ResolveMediaPath() failed to create directory: %v", got)
			}
		})
	}
}

func TestListDirectory(t *testing.T) {
	tmpDir := t.TempDir()

	// Create a dummy structure
	_ = os.Mkdir(filepath.Join(tmpDir, "subdir"), 0755)
	_ = os.WriteFile(filepath.Join(tmpDir, "file.txt"), []byte("test"), 0644)

	tests := []struct {
		name          string
		pathStr       string
		workspacePath string
		wantContains  []string
	}{
		{
			name:          "list current dir",
			pathStr:       ".",
			workspacePath: tmpDir,
			wantContains:  []string{"📁 subdir", "📄 file.txt"},
		},
		{
			name:          "list subdir",
			pathStr:       "subdir",
			workspacePath: tmpDir,
			wantContains:  []string{"Directory subdir is empty"},
		},
		{
			name:          "directory not found",
			pathStr:       "missing",
			workspacePath: tmpDir,
			wantContains:  []string{"Error: Directory not found: missing"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := ListDirectory(tt.pathStr, tt.workspacePath)
			for _, want := range tt.wantContains {
				if !strings.Contains(got, want) {
					t.Errorf("ListDirectory() = %v, want to contain %v", got, want)
				}
			}
		})
	}
}

func TestReadLogFile(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("Skipping Windows-specific ReadLogFile test")
	}

	tmpDir := t.TempDir()

	// Create a log file with BOM
	logPath := filepath.Join(tmpDir, "test.log")
	bom := []byte{0xEF, 0xBB, 0xBF}
	content := "log content"
	_ = os.WriteFile(logPath, append(bom, []byte(content)...), 0644)

	// Create a large log file
	largeLogPath := filepath.Join(tmpDir, "large.log")
	largeContent := strings.Repeat("A", 1000)
	_ = os.WriteFile(largeLogPath, []byte(largeContent), 0644)

	tests := []struct {
		name          string
		pathStr       string
		workspacePath string
		maxChars      int
		wantContent   string
		wantOk        bool
	}{
		{
			name:          "read valid log",
			pathStr:       "test.log",
			workspacePath: tmpDir,
			maxChars:      100,
			wantContent:   content,
			wantOk:        true,
		},
		{
			name:          "read non-log file",
			pathStr:       "test.txt",
			workspacePath: tmpDir,
			maxChars:      100,
			wantContent:   "",
			wantOk:        false,
		},
		{
			name:          "file not found",
			pathStr:       "missing.log",
			workspacePath: tmpDir,
			maxChars:      100,
			wantContent:   "Error: File not found",
			wantOk:        true,
		},
		{
			name:          "truncate content",
			pathStr:       "large.log",
			workspacePath: tmpDir,
			maxChars:      500,
			wantContent:   strings.Repeat("A", 500) + "\n\n... (truncated)",
			wantOk:        true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, ok := ReadLogFile(tt.pathStr, tt.workspacePath, tt.maxChars)
			if ok != tt.wantOk {
				t.Errorf("ReadLogFile() ok = %v, want %v", ok, tt.wantOk)
			}
			if tt.wantOk && !strings.Contains(got, tt.wantContent) {
				t.Errorf("ReadLogFile() = %v, want to contain %v", got, tt.wantContent)
			}
		})
	}
}
