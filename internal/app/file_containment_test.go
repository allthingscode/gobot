//nolint:testpackage // Tests private candidate/error classification without exporting a test API.
package app

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestFileContainmentCandidate(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	for _, tc := range []struct {
		name, path, root, want string
		outside                bool
	}{
		{"relative", "file.txt", root, "file.txt", false},
		{"absolute", filepath.Join(root, "file.txt"), root, "file.txt", false},
		{"dotdot name", "..notes", root, "..notes", false},
		{"root", root, root, ".", false},
		{"traversal", filepath.Join("..", "file.txt"), root, "", true},
		{"sibling prefix", root + "-sibling/file.txt", root, "", true},
		{"empty root", "file.txt", "", "", true},
		{"relative root", "file.txt", ".", "file.txt", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got, err := fileRootCandidate(tc.path, tc.root)
			if errors.Is(err, errFileOutsideRoot) != tc.outside || got != tc.want {
				t.Fatalf("candidate = %q, %v; want %q, outside=%v", got, err, tc.want, tc.outside)
			}
		})
	}
}

func TestFileContainmentReadFailures(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	file := filepath.Join(root, "file")
	if err := os.WriteFile(file, []byte("dummy"), 0o600); err != nil {
		t.Fatal(err)
	}
	tool := &ReadTextFileTool{}
	for _, tc := range []struct {
		name, path, root string
		missing, outside bool
	}{
		{"missing file", "missing", root, true, false},
		{"missing root", "file", filepath.Join(root, "missing"), true, false},
		{"root is file", "file", file, false, false},
		{"read directory", ".", root, false, false},
		{"empty root", "file", "", false, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got, err := tool.readFileFromRoot(tc.path, tc.root)
			if err == nil || len(got) != 0 || errors.Is(err, os.ErrNotExist) != tc.missing || errors.Is(err, errFileOutsideRoot) != tc.outside {
				t.Fatalf("read = %q, %v; missing=%v outside=%v", got, err, tc.missing, tc.outside)
			}
		})
	}
}
