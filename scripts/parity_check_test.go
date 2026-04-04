package scripts_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// runParityCheck runs the parity_check script in the given directory.
func runParityCheck(t *testing.T, dir string) (string, error) {
	t.Helper()
	cmd := exec.Command("go", "run", filepath.Join(srcDir, "parity_check.go"))
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func setupParityProject(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	for _, sub := range []string{
		filepath.Join(dir, "internal"),
		filepath.Join(dir, "cmd"),
	} {
		if err := os.MkdirAll(sub, 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
	}
	return dir
}

func TestParityCheck_NoReferences(t *testing.T) {
	dir := setupParityProject(t)
	// No UPSTREAM_REFERENCES.md — should skip gracefully.
	out, err := runParityCheck(t, dir)
	if err != nil {
		t.Errorf("should pass when file is missing, got: %v\noutput:\n%s", err, out)
	}
	if want := "not found"; !contains(out, want) {
		t.Errorf("expected skip message, got:\n%s", out)
	}
}

func TestParityCheck_TagFound(t *testing.T) {
	dir := setupParityProject(t)
	writeFile(t, filepath.Join(dir, "UPSTREAM_REFERENCES.md"),
		"<!-- tag: FOO_BAR -->\nSome reference.\n")
	// Source code contains the tag as a word.
	writeFile(t, filepath.Join(dir, "internal", "foo.go"),
		"package internal\n\n// FOO_BAR is a reference tag.\nconst FOO_BAR = 1\n")
	out, err := runParityCheck(t, dir)
	if err != nil {
		t.Errorf("tag should be found, got: %v\noutput:\n%s", err, out)
	}
}

func TestParityCheck_TagMissing(t *testing.T) {
	dir := setupParityProject(t)
	writeFile(t, filepath.Join(dir, "UPSTREAM_REFERENCES.md"),
		"<!-- tag: MISSING_TAG -->\nSome reference.\n")
	out, err := runParityCheck(t, dir)
	if err == nil {
		t.Error("expected failure for missing tag")
	}
	if want := "MISSING_TAG"; !contains(out, want) {
		t.Errorf("output should mention MISSING_TAG, got:\n%s", out)
	}
}

func TestParityCheck_NoSubstringMatch(t *testing.T) {
	dir := setupParityProject(t)
	// Tag FOO should NOT match FOOBAR.
	writeFile(t, filepath.Join(dir, "UPSTREAM_REFERENCES.md"),
		"<!-- tag: FOO -->\nSome reference.\n")
	writeFile(t, filepath.Join(dir, "internal", "foo.go"),
		"package internal\n\nconst FOOBAR = 1\n")
	out, err := runParityCheck(t, dir)
	if err == nil {
		t.Error("FOO should not match FOOBAR (substring)")
	}
	if want := "FOO"; !contains(out, want) {
		t.Errorf("output should list FOO as missing, got:\n%s", out)
	}
}

func TestParityCheck_WordBoundaryMatch(t *testing.T) {
	dir := setupParityProject(t)
	// Tag FOO should match as a standalone word.
	writeFile(t, filepath.Join(dir, "UPSTREAM_REFERENCES.md"),
		"<!-- tag: FOO -->\nSome reference.\n")
	writeFile(t, filepath.Join(dir, "internal", "foo.go"),
		"package internal\n\n// FOO is used in this file.\nvar FOO_COUNT = 42\n")
	out, err := runParityCheck(t, dir)
	if err != nil {
		t.Errorf("FOO should match as a word, got: %v\noutput:\n%s", err, out)
	}
}

func TestParityCheck_MultipleTags(t *testing.T) {
	dir := setupParityProject(t)
	writeFile(t, filepath.Join(dir, "UPSTREAM_REFERENCES.md"),
		"<!-- tag: ALPHA -->\n<!-- tag: BETA -->\n<!-- tag: GAMMA -->\n")
	writeFile(t, filepath.Join(dir, "internal", "alpha.go"),
		"package internal\n\nconst ALPHA = 1\n")
	writeFile(t, filepath.Join(dir, "internal", "beta.go"),
		"package internal\n\nconst BETA = 2\n")
	// GAMMA is missing.
	out, err := runParityCheck(t, dir)
	if err == nil {
		t.Error("expected failure for missing GAMMA")
	}
	if want := "GAMMA"; !contains(out, want) {
		t.Errorf("output should mention GAMMA, got:\n%s", out)
	}
	if contains(out, "ALPHA") || contains(out, "BETA") {
		t.Errorf("output should not list found tags ALPHA/BETA, got:\n%s", out)
	}
}
