package main

import (
    "os"
    "path/filepath"
    "strings"
    "testing"
)

func TestBuildAwarenessContent(t *testing.T) {
    content := buildAwarenessContent("/storage/root")
    checks := []string{
        "STRATEGIC AWARENESS",
        "/storage/root",
        "jobs",
        "YAML front-matter",
        "Daily Journal",
        "OPERATOR MANDATES",
    }
    for _, want := range checks {
        if !strings.Contains(content, want) {
            t.Errorf("buildAwarenessContent: missing %q", want)
        }
    }
}

func TestEnsureAwarenessFile(t *testing.T) {
    dir := t.TempDir()

    // First call: should create the file.
    ensureAwarenessFile(dir)
    path := filepath.Join(dir, "workspace", "AWARENESS.md")
    data, err := os.ReadFile(path)
    if err != nil {
        t.Fatalf("file not created: %v", err)
    }
    if !strings.Contains(string(data), "STRATEGIC AWARENESS") {
        t.Error("file missing expected header")
    }

    // Second call: should not overwrite existing content.
    if err := os.WriteFile(path, []byte("custom content"), 0o644); err != nil {
        t.Fatal(err)
    }
    ensureAwarenessFile(dir)
    data2, _ := os.ReadFile(path)
    if string(data2) != "custom content" {
        t.Error("ensureAwarenessFile overwrote existing file")
    }
}
