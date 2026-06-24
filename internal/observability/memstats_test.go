//nolint:testpackage // exercises unexported bytesPerMiB conversion constant
package observability

import "testing"

func TestReadMemSnapshot(t *testing.T) {
	t.Parallel()
	s := ReadMemSnapshot()

	if s.SysBytes == 0 {
		t.Fatal("SysBytes should be > 0 for a running process")
	}
	if s.SysMiB() <= 0 {
		t.Errorf("SysMiB() = %f, want > 0", s.SysMiB())
	}
	if s.HeapAllocMiB() < 0 {
		t.Errorf("HeapAllocMiB() = %f, want >= 0", s.HeapAllocMiB())
	}
}

func TestMemSnapshotMiBConversion(t *testing.T) {
	t.Parallel()
	s := MemSnapshot{HeapAllocBytes: 2 * bytesPerMiB, SysBytes: 8 * bytesPerMiB}

	if got := s.HeapAllocMiB(); got != 2 {
		t.Errorf("HeapAllocMiB() = %f, want 2", got)
	}
	if got := s.SysMiB(); got != 8 {
		t.Errorf("SysMiB() = %f, want 8", got)
	}
}
