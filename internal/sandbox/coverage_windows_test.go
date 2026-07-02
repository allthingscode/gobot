//go:build windows

//nolint:testpackage // covers package-private Windows helpers
package sandbox

import (
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
