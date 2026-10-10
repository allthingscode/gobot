package app

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

var errFileOutsideRoot = errors.New("outside root")

// readFileFromRoot reads through a directory capability, never a checked host
// pathname. On Windows and native Unix, Root confines traversal during open:
// concurrent link replacement can fail or select another in-root file, but
// cannot authorize an outside target. JS/Plan9 are outside this assurance.
//
// Relative in-root symlinks are allowed. Escaping/absolute symlinks, loops and
// unsupported reparse points fail closed; Windows junctions may be rejected even
// in-root. Configured roots (including linked roots) and initial acquisition are
// trusted. This is not an OS sandbox: privileged filesystem manipulation, hard
// links already in the tree, bind mounts, /proc and device files are not confined.
func (t *ReadTextFileTool) readFileFromRoot(path, root string) ([]byte, error) {
	candidate, err := fileRootCandidate(path, root)
	if err != nil {
		return nil, err
	}
	absoluteRoot, err := filepath.Abs(root)
	if err != nil {
		return nil, fmt.Errorf("resolve file root: %w", err)
	}
	dir, err := os.OpenRoot(absoluteRoot)
	if err != nil {
		return nil, fmt.Errorf("open file root: %w", err)
	}
	data, readErr := dir.ReadFile(candidate)
	closeErr := dir.Close()
	if readErr != nil {
		return nil, fmt.Errorf("read file within root: %w", readErr)
	}
	if closeErr != nil {
		return nil, fmt.Errorf("close file root: %w", closeErr)
	}
	return data, nil
}

func fileRootCandidate(path, root string) (string, error) {
	if root == "" {
		return "", fmt.Errorf("empty root: %w", errFileOutsideRoot)
	}
	absoluteRoot, err := filepath.Abs(root)
	if err != nil {
		return "", fmt.Errorf("resolve file root: %w", err)
	}
	fullPath := path
	if !filepath.IsAbs(path) {
		fullPath = filepath.Join(absoluteRoot, path)
	}
	rel, err := filepath.Rel(absoluteRoot, filepath.Clean(fullPath))
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("path %q is outside root %q: %w", path, root, errFileOutsideRoot)
	}
	return rel, nil
}
