package scripts_test

import (
	"context"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
)

func TestParityCheck_Run(t *testing.T) {
	_, thisFile, _, _ := runtime.Caller(0)
	srcDir := filepath.Dir(thisFile)
	projectRoot := filepath.Dir(srcDir)

	runParityCheck := func(t *testing.T, dir string) (string, error) {
		t.Helper()
		// #nosec G204
		cmd := exec.CommandContext(context.Background(), "go", "run", filepath.Join(srcDir, "parity_check.go"))
		cmd.Dir = dir
		out, err := cmd.CombinedOutput()
		return string(out), err
	}

	t.Run("CleanCodebase", func(t *testing.T) {
		t.Parallel()
		out, err := runParityCheck(t, projectRoot)
		if err != nil {
			t.Errorf("parity_check failed: %v\nOutput: %s", err, out)
		}
	})
}
