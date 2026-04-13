// Package infra provides infrastructure and filesystem utilities for the gobot project.
package infra

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
)

// ResolveMediaPath constructs the strategic media storage path and creates directories.
// Ported from resolve_strategic_media_path in infra_logic.py.
func ResolveMediaPath(storageRoot, channelName string) string {
	if storageRoot == "" {
		// Fallback should be handled by config.StorageRoot() callers,
		// but as a last resort infra should not assume a specific drive.
		storageRoot = "."
	}

	path := filepath.Join(storageRoot, "workspace", "media")
	if channelName != "" {
		path = filepath.Join(path, channelName)
	}

	// Create directories (equivalent to mkdir -p)
	_ = os.MkdirAll(path, 0o755)

	return path
}

// ListDirectory robustly lists directory contents, skipping restricted Windows items.
// Ported from list_directory_robust in infra_logic.py.
func ListDirectory(pathStr, workspacePath string) string {
	dirPath := pathStr
	if !filepath.IsAbs(dirPath) {
		dirPath = filepath.Join(workspacePath, dirPath)
	}
	dirPath = filepath.Clean(dirPath)

	entries, err := os.ReadDir(dirPath)
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Sprintf("Error: Directory not found: %s", pathStr)
		}
		return fmt.Sprintf("Error accessing directory contents: %v", err)
	}

	if len(entries) == 0 {
		return fmt.Sprintf("Directory %s is empty (or all items are restricted)", pathStr)
	}

	items := make([]string, 0, len(entries))
	for _, entry := range entries {
		prefix := "📄 "
		if entry.IsDir() {
			prefix = "📁 "
		}
		items = append(items, fmt.Sprintf("%s%s", prefix, entry.Name()))
	}

	sort.Strings(items)

	return strings.Join(items, "\n")
}

// ReadLogFile reads a log file using Windows-safe encoding and size guards.
// Ported from read_log_file_robust in infra_logic.py.
// Returns ("", false) if not a .log file or not on Windows.
func ReadLogFile(pathStr, workspacePath string, maxChars int) (string, bool) {
	if !strings.HasSuffix(strings.ToLower(pathStr), ".log") || runtime.GOOS != "windows" {
		return "", false
	}

	filePath := pathStr
	if !filepath.IsAbs(filePath) {
		filePath = filepath.Join(workspacePath, filePath)
	}
	filePath = filepath.Clean(filePath)

	info, err := os.Stat(filePath)
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Sprintf("Error: File not found: %s", pathStr), true
		}
		return fmt.Sprintf("Error reading log file strategically: %v", err), true
	}

	// Conservative size guard: 4 bytes per char (UTF-8)
	if info.Size() > int64(maxChars*4) {
		return fmt.Sprintf("Error: File too large (%d bytes).", info.Size()), true
	}

	data, err := os.ReadFile(filePath)
	if err != nil {
		return fmt.Sprintf("Error reading log file strategically: %v", err), true
	}

	// Handle UTF-8-BOM (utf-8-sig equivalent)
	bom := []byte{0xEF, 0xBB, 0xBF}
	data = bytes.TrimPrefix(data, bom)

	content := string(data)
	if len(content) > maxChars {
		return content[:maxChars] + "\n\n... (truncated)", true
	}

	return content, true
}
