package scripts_test

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// srcDir is the directory containing the scripts under test.
//nolint:gochecknoglobals // Test helper: set once during init(), not mutable runtime state
var srcDir string

func init() {
	_, thisFile, _, _ := runtime.Caller(0)
	srcDir = filepath.Dir(thisFile)
}

// runDocLint runs the doc_lint script in the given directory and returns
// combined stdout+stderr output and any error.
func runDocLint(t *testing.T, dir string) (string, error) {
	t.Helper()
	// #nosec G204 - test tool, not a security risk
	cmd := exec.CommandContext(context.Background(), "go", "run", filepath.Join(srcDir, "doc_lint.go"))
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func setupTempProject(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	for _, sub := range []string{
		filepath.Join(dir, "internal"),
		filepath.Join(dir, "cmd"),
		filepath.Join(dir, "cmd", "gobot"),
	} {
		if err := os.MkdirAll(sub, 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
	}
	return dir
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func TestDocLint_CleanProject(t *testing.T) {
	t.Parallel()
	dir := setupTempProject(t)
	out, err := runDocLint(t, dir)
	if err != nil {
		t.Errorf("expected pass on clean project, got error: %v\noutput:\n%s", err, out)
	}
}

func TestDocLint_MissingDocComment(t *testing.T) {
	t.Parallel()
	dir := setupTempProject(t)
	writeFile(t, filepath.Join(dir, "internal", "foo.go"),
		"package internal\n\nfunc ExportedFunc() {}\n")
	out, err := runDocLint(t, dir)
	if err == nil {
		t.Error("expected failure for missing doc comment")
	}
	if want := "ExportedFunc"; !strings.Contains(out, want) {
		t.Errorf("output should mention %q, got:\n%s", want, out)
	}
}

func TestDocLint_MainSkipped(t *testing.T) {
	t.Parallel()
	dir := setupTempProject(t)
	writeFile(t, filepath.Join(dir, "cmd", "gobot", "main.go"),
		"package main\n\nfunc main() {}\n")
	out, err := runDocLint(t, dir)
	if err != nil {
		t.Errorf("main() should be skipped, got error: %v\noutput:\n%s", err, out)
	}
}

func TestDocLint_UnexportedSkipped(t *testing.T) {
	t.Parallel()
	dir := setupTempProject(t)
	writeFile(t, filepath.Join(dir, "internal", "foo.go"),
		"package internal\n\nfunc helper() {}\n")
	out, err := runDocLint(t, dir)
	if err != nil {
		t.Errorf("unexported func should be skipped, got error: %v\noutput:\n%s", err, out)
	}
}

func TestDocLint_MethodSkipped(t *testing.T) {
	t.Parallel()
	dir := setupTempProject(t)
	writeFile(t, filepath.Join(dir, "internal", "foo.go"),
		"package internal\n\ntype T struct{}\n\nfunc (T) ExportedMethod() {}\n")
	out, err := runDocLint(t, dir)
	if err != nil {
		t.Errorf("methods should be skipped, got error: %v\noutput:\n%s", err, out)
	}
}
