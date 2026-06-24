package observability

import "runtime"

// MemSnapshot is a point-in-time view of process memory drawn from
// runtime.ReadMemStats. It is the single in-process source for footprint
// reporting (the doctor "memory" line and the boot DEBUG log), replacing the
// previous practice of one-off external tasklist snapshots (R-013).
type MemSnapshot struct {
	// HeapAllocBytes is bytes of allocated, still-reachable heap objects.
	HeapAllocBytes uint64
	// SysBytes is total bytes of memory obtained from the OS (the closest
	// in-process analogue to RSS; always > 0 for a running process).
	SysBytes uint64
}

const bytesPerMiB = 1024 * 1024

// ReadMemSnapshot samples current process memory. runtime.ReadMemStats stops the
// world briefly, so call it sparingly (at boot and per doctor run), never on a hot path.
func ReadMemSnapshot() MemSnapshot {
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	return MemSnapshot{HeapAllocBytes: m.HeapAlloc, SysBytes: m.Sys}
}

// HeapAllocMiB returns HeapAllocBytes in mebibytes.
func (s MemSnapshot) HeapAllocMiB() float64 { return float64(s.HeapAllocBytes) / bytesPerMiB }

// SysMiB returns SysBytes in mebibytes.
func (s MemSnapshot) SysMiB() float64 { return float64(s.SysBytes) / bytesPerMiB }
