//go:build windows

//nolint:testpackage // covers package-private Windows helpers
package sandbox

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/windows"
)

func TestApplyJobLimitsWithMemoryAndCPU(t *testing.T) {
	t.Parallel()

	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		t.Fatalf("CreateJobObject: %v", err)
	}
	t.Cleanup(func() { _ = windows.CloseHandle(job) })

	if err := applyJobLimits(job, Config{MaxMemoryMB: 64, MaxCPUSec: 2}); err != nil {
		t.Fatalf("applyJobLimits: %v", err)
	}
}

func TestResumeThreadInvalidID(t *testing.T) {
	t.Parallel()

	if err := resumeThread(^uint32(0)); err == nil {
		t.Fatal("expected invalid thread id error")
	}
}

func TestFindFirstThreadForPIDReportsMissingPID(t *testing.T) {
	t.Parallel()

	snap, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPTHREAD, 0)
	if err != nil {
		t.Fatalf("CreateToolhelp32Snapshot: %v", err)
	}
	t.Cleanup(func() { _ = windows.CloseHandle(snap) })

	_, err = findFirstThreadForPID(snap, ^uint32(0))
	if err == nil {
		t.Fatal("expected missing thread error")
	}
	if !strings.Contains(err.Error(), "no thread found for PID") {
		t.Fatalf("expected missing PID error, got %v", err)
	}
}

func TestExecutorInvalidSandboxRoot(t *testing.T) {
	t.Parallel()

	rootFile := filepath.Join(t.TempDir(), "root-file")
	if err := os.WriteFile(rootFile, []byte("not a directory"), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	exec := New(Config{SandboxRoot: filepath.Join(rootFile, "child")})
	_, err := exec.Run(context.Background(), "cmd", []string{"/c", "echo unreachable"})
	if err == nil {
		t.Fatal("expected sandbox root mkdir error")
	}
	if !strings.Contains(err.Error(), "sandbox: mkdir") {
		t.Fatalf("expected mkdir error, got %v", err)
	}
}
