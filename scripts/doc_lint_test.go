package scripts_test

import (
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
	cmd := exec.Command("go", "run", filepath.Join(srcDir, "doc_lint.go")) // #nosec G204 - test tool, not a security risk
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func setupTempProject(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	// Create required directory structure.
	for _, sub := range []string{
		filepath.Join(dir, "internal"),
		filepath.Join(dir, "cmd"),
		filepath.Join(dir, "cmd", "gobot"),
		filepath.Join(dir, ".private", "backlog", "features", "active"),
		filepath.Join(dir, ".private", "backlog", "bugs", "active"),
		filepath.Join(dir, ".private", "backlog", "chores", "active"),
		filepath.Join(dir, ".private", "backlog", "archived"),
		filepath.Join(dir, ".private", "session"),
		filepath.Join(dir, ".private", "session", "handoffs"),
		filepath.Join(dir, ".private", "session", "global"),
		filepath.Join(dir, ".private", "locks"),
	} {
		if err := os.MkdirAll(sub, 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
	}
	// Minimal BACKLOG.md.
	writeFile(t, filepath.Join(dir, ".private", "backlog", "BACKLOG.md"),
		"# Backlog\n\n## Features\n\n## Bugs\n\n## Chores\n\n")
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

func TestDocLint_StaleReference(t *testing.T) {
	t.Parallel()
	dir := setupTempProject(t)
	writeFile(t, filepath.Join(dir, ".private", "backlog", "features", "active", "F-999.md"),
		"---\nstatus: \"Planning\"\n---\n\nSee `internal/nonexistent.go` for details.\n")
	out, err := runDocLint(t, dir)
	if err == nil {
		t.Error("expected failure for stale reference")
	}
	if want := "nonexistent.go"; !strings.Contains(out, want) {
		t.Errorf("output should mention %q, got:\n%s", want, out)
	}
}

func TestDocLint_UnindexedItem(t *testing.T) {
	t.Parallel()
	dir := setupTempProject(t)
	writeFile(t, filepath.Join(dir, ".private", "backlog", "features", "active", "F-999_Orphan.md"),
		"---\nstatus: \"Planning\"\n---\n\nAn orphaned feature.\n")
	out, err := runDocLint(t, dir)
	if err == nil {
		t.Error("expected failure for unindexed backlog item")
	}
	if want := "not referenced in BACKLOG.md"; !strings.Contains(out, want) {
		t.Errorf("output should mention unindexed item, got:\n%s", out)
	}
}

func TestDocLint_InvalidStatus(t *testing.T) {
	t.Parallel()
	dir := setupTempProject(t)
	writeFile(t, filepath.Join(dir, ".private", "backlog", "features", "active", "F-999_Bad.md"),
		"---\nstatus: \"NonExistentStatus\"\n---\n\nBad status.\n")
	writeFile(t, filepath.Join(dir, ".private", "backlog", "BACKLOG.md"),
		"# Backlog\n\nF-999_Bad.md\n\n## Features\n\n## Bugs\n\n")
	out, err := runDocLint(t, dir)
	if err == nil {
		t.Error("expected failure for invalid status")
	}
	if want := "invalid status"; !strings.Contains(out, want) {
		t.Errorf("output should mention invalid status, got:\n%s", out)
	}
}

func TestDocLint_ValidStatuses(t *testing.T) {
	t.Parallel()
	statuses := []string{
		"Production", "In Progress", "Planning", "Draft", "Archived", "Resolved",
		"Ready", "Ready for Review", "Ready for Deploy",
	}
	for _, s := range statuses {
		t.Run(s, func(t *testing.T) {
			t.Parallel()
			dir := setupTempProject(t)
			writeFile(t, filepath.Join(dir, ".private", "backlog", "features", "active", "F-001.md"),
				"---\nstatus: \""+s+"\"\n---\n\nItem.\n")
			writeFile(t, filepath.Join(dir, ".private", "backlog", "BACKLOG.md"),
				"# Backlog\n\nF-001.md\n\n## Features\n\n## Bugs\n\n")
			out, err := runDocLint(t, dir)
			if err != nil {
				t.Errorf("status %q should be valid, got error: %v\noutput:\n%s", s, err, out)
			}
		})
	}
}

func TestDocLint_InvalidHandoffJSON(t *testing.T) {
	t.Parallel()
	dir := setupTempProject(t)
	writeFile(t, filepath.Join(dir, ".private", "session", "handoffs", "test.json"),
		`{invalid json}`)
	out, err := runDocLint(t, dir)
	if err == nil {
		t.Error("expected failure for invalid handoff.json")
	}
	if want := "invalid JSON"; !strings.Contains(out, want) {
		t.Errorf("output should mention invalid JSON, got:\n%s", out)
	}
}

func TestDocLint_MissingHandoffField(t *testing.T) {
	t.Parallel()
	dir := setupTempProject(t)
	writeFile(t, filepath.Join(dir, ".private", "session", "handoffs", "test.json"),
		`{"task_id": "F-001"}`)
	out, err := runDocLint(t, dir)
	if err == nil {
		t.Error("expected failure for missing required fields")
	}
	if want := "missing required field"; !strings.Contains(out, want) {
		t.Errorf("output should mention missing field, got:\n%s", out)
	}
}

func TestDocLint_ValidHandoff(t *testing.T) {
	t.Parallel()
	dir := setupTempProject(t)
	taskFile := filepath.Join(dir, ".private", "session", "task.md")
	writeFile(t, taskFile, "Task details.\n")
	writeFile(t, filepath.Join(dir, ".private", "session", "handoff.json"),
		`{
			"task_id": "F-001",
			"source_specialist": "architect",
			"target_specialist": "reviewer",
			"state_file_path": ".private/session/task.md",
			"timestamp": "2026-04-04T12:00:00Z"
		}`)
	out, err := runDocLint(t, dir)
	if err != nil {
		t.Errorf("valid handoff should pass, got error: %v\noutput:\n%s", err, out)
	}
}
