package testutil_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/allthingscode/gobot/internal/testutil"
)

//nolint:paralleltest // verifies process environment isolation with t.Setenv
func TestIsolateEnvironment_ProfileDirectories(t *testing.T) {
	ambient := t.TempDir()
	for _, key := range []string{"HOME", "USERPROFILE", "APPDATA", "LOCALAPPDATA", "XDG_CONFIG_HOME", "XDG_DATA_HOME"} {
		t.Setenv(key, ambient)
	}
	root := filepath.Dir(testutil.IsolateEnvironment(t))
	for key, suffix := range map[string]string{
		"HOME": "", "USERPROFILE": "", "APPDATA": "config", "LOCALAPPDATA": "local",
		"XDG_CONFIG_HOME": "config", "XDG_DATA_HOME": "data",
	} {
		if os.Getenv(key) != filepath.Join(root, suffix) {
			t.Errorf("%s did not move into the fixture", key)
		}
	}
	home, err := os.UserHomeDir()
	if err != nil || home != root {
		t.Fatalf("UserHomeDir did not resolve to fixture: %v", err)
	}
	config, err := os.UserConfigDir()
	if err != nil {
		t.Fatal(err)
	}
	rel, err := filepath.Rel(root, config)
	if err != nil || !filepath.IsLocal(rel) {
		t.Fatalf("UserConfigDir escaped fixture: %v", err)
	}
}
