//go:build windows

package app_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func dummyJunction(t *testing.T, target, link string) {
	t.Helper()
	//nolint:gosec // mklink receives only isolated dummy fixture paths; no external input.
	output, err := exec.CommandContext(t.Context(), "cmd", "/c", "mklink", "/J", link, target).CombinedOutput()
	if err != nil {
		t.Fatalf("dummy junction fixture unavailable: %v: %s", err, output)
	}
	// Remove the junction entry before TempDir recursively cleans fixture trees.
	t.Cleanup(func() {
		if err := os.Remove(link); err != nil {
			t.Errorf("remove dummy junction: %v", err)
		}
	})
}

func TestFileContainmentWindowsJunctions(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name, root string
		inRoot     bool
	}{
		{"workspace outside blocks project fallback", "workspace", false},
		{"project outside", "project", false},
		{"workspace in-root absolute junction rejected", "workspace", true},
		{"project in-root absolute junction rejected", "project", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			tool, _, workspace, project, outside := containmentFixture(t)
			root, target := workspace, outside
			if tc.root == "project" {
				root = project
			} else {
				if err := os.Mkdir(filepath.Join(project, "junction"), 0o755); err != nil {
					t.Fatal(err)
				}
				writeDummy(t, filepath.Join(project, "junction", "marker"), "safe fallback must not be read")
			}
			if tc.inRoot {
				target = root
			}
			dummyJunction(t, target, filepath.Join(root, "junction"))
			got, err := readDummy(tool, filepath.Join("junction", "marker"))
			if err == nil || got != "" {
				t.Fatalf("junction read = %q, %v; want terminal denial", got, err)
			}
		})
	}
}

func TestFileContainmentWindowsPaths(t *testing.T) {
	t.Parallel()
	tool, _, workspace, _, _ := containmentFixture(t)
	drive := "Z:"
	if strings.EqualFold(filepath.VolumeName(workspace), drive) {
		drive = "Y:"
	}
	for _, path := range []string{drive + `\marker`, `\\dummy-server\dummy-share\marker`, "NUL"} {
		got, err := readDummy(tool, path)
		if err == nil || got != "" {
			t.Errorf("read %q = %q, %v; want denial", path, got, err)
		}
	}
	volume := filepath.VolumeName(workspace)
	lowerDrivePath := strings.ToLower(volume) + strings.TrimPrefix(filepath.Join(workspace, "marker"), volume)
	got, err := readDummy(tool, lowerDrivePath)
	if err != nil || got != "workspace" {
		t.Fatalf("case-insensitive drive read = %q, %v", got, err)
	}
}

func TestWireSubToolsWindowsJunction(t *testing.T) {
	t.Parallel()
	_, cfg, workspace, _, outside := containmentFixture(t)
	dummyJunction(t, outside, filepath.Join(workspace, "junction"))
	got, err := readDummy(spawnedReadTool(t, cfg), filepath.Join("junction", "marker"))
	if err == nil || got != "" {
		t.Fatalf("spawned junction read = %q, %v", got, err)
	}
}
