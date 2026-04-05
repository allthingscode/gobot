package main

import (
	"os/exec"
	"strings"
	"testing"
)

// TestPanicFix verifies that passing an invalid flag does not panic
// but instead logs an error and exits with code 1.
func TestPanicFix(t *testing.T) {
	// We run the command itself as a subprocess.
	// Since we are in the 'main' package, we can't easily run 'go run main.go' 
	// without knowing the absolute path or building it.
	// However, we can use 'go run .' if we are in the right directory.
	
	cmd := exec.Command("go", "run", "-mod=readonly", ".", "--invalid-flag")
	// Set the working directory to the current directory (cmd/gobot)
	// so 'go run .' works.
	cmd.Dir = "."
	
	output, err := cmd.CombinedOutput()
	
	// 'go run' returns an error if the subprocess exits with non-zero.
	if err == nil {
		t.Fatal("Expected error (exit code 1) for invalid flag, but got nil")
	}

	exitErr, ok := err.(*exec.ExitError)
	if !ok {
		t.Fatalf("Expected *exec.ExitError, got %T", err)
	}

	if exitErr.ExitCode() != 1 {
		t.Errorf("Expected exit code 1, got %d", exitErr.ExitCode())
	}

	outStr := string(output)
	if strings.Contains(outStr, "panic:") {
		t.Errorf("Output contains 'panic:', fix failed:\n%s", outStr)
	}

	if !strings.Contains(outStr, "ERROR fatal command error") {
		t.Errorf("Output does not contain expected error log message:\n%s", outStr)
	}
	
	if !strings.Contains(outStr, "unknown flag: --invalid-flag") {
		t.Errorf("Output does not contain 'unknown flag: --invalid-flag':\n%s", outStr)
	}
}
