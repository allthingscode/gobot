package state

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// WriteFileAtomic writes data to a temporary file and renames it atomically to the target path.
// This ensures that the file is either fully written or not present at all.
func WriteFileAtomic(path string, data []byte, perm os.FileMode) error {
	// Ensure the parent directory exists.
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0750); err != nil {
		return fmt.Errorf("creating directory %s: %w", dir, err)
	}

	// Create a temporary file in the same directory for atomic rename.
	tempFile, err := os.CreateTemp(dir, ".tmp_")
	if err != nil {
		return fmt.Errorf("creating temp file: %w", err)
	}
	tempPath := tempFile.Name()

	// Clean up temp file on any error.
	defer func() {
		_ = os.Remove(tempPath)
	}()

	// Write data to temp file.
	if _, err := tempFile.Write(data); err != nil {
		_ = tempFile.Close()
		return fmt.Errorf("writing to temp file: %w", err)
	}

	// Set permissions before closing.
	if err := tempFile.Chmod(perm); err != nil {
		_ = tempFile.Close()
		return fmt.Errorf("setting file permissions: %w", err)
	}

	if err := tempFile.Close(); err != nil {
		return fmt.Errorf("closing temp file: %w", err)
	}

	// Atomic rename: this is atomic on POSIX and Windows (with caveats).
	if err := os.Rename(tempPath, path); err != nil {
		return fmt.Errorf("renaming temp file: %w", err)
	}

	// Success - prevent cleanup defer from removing the file.
	return nil
}

// ReadFileJSON reads a JSON file and unmarshals it into v.
func ReadFileJSON(path string, v any) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("reading file %s: %w", path, err)
	}

	if err := json.Unmarshal(data, v); err != nil {
		return fmt.Errorf("unmarshaling JSON from %s: %w", path, err)
	}

	return nil
}

// WriteFileJSON marshals v to JSON and writes it atomically to path.
func WriteFileJSON(path string, v any, perm os.FileMode) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return fmt.Errorf("marshaling JSON: %w", err)
	}

	// Append newline for POSIX compliance.
	data = append(data, '\n')

	return WriteFileAtomic(path, data, perm)
}
