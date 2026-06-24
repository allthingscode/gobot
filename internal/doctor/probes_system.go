package doctor

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/observability"
	"github.com/allthingscode/gobot/internal/resilience"
)

// checkMemory reports current process memory (Go heap + OS-obtained Sys) as an
// informational doctor line. It is the in-process replacement for ad-hoc tasklist
// snapshots (R-013); always OK (no ceiling logic - R-013 found GC/limit tuning is
// not a lever, so a hard ceiling is not yet justified).
func checkMemory() Result {
	s := observability.ReadMemSnapshot()
	return Result{
		Name:   "memory",
		OK:     true,
		Detail: fmt.Sprintf("heap %.1f MiB, sys %.1f MiB", s.HeapAllocMiB(), s.SysMiB()),
	}
}

// checkResilience returns results for all registered circuit breakers.
func checkResilience() []Result {
	breakers := resilience.All()
	if len(breakers) == 0 {
		return []Result{{Name: "resilience", OK: true, Detail: "no circuit breakers registered"}}
	}

	results := make([]Result, 0, len(breakers))
	for name, b := range breakers {
		state := b.State()
		stats := resilience.GetStats(name)
		detail := fmt.Sprintf("state: %s, succ: %d, fail: %d, rej: %d",
			state, stats.Successes, stats.Failures, stats.Rejections)

		ok := true
		rem := ""
		if state == "open" {
			ok = false
			rem = "The service is currently failing; wait for the circuit breaker to close or check the underlying service health."
		}
		results = append(results, Result{
			Name:        "breaker: " + name,
			OK:          ok,
			Detail:      detail,
			Remediation: rem,
		})
	}
	return results
}

// checkConcurrency returns results for all session locks that have recorded metrics.
func checkConcurrency() []Result {
	metrics := agent.GetLockMetrics()
	if len(metrics) == 0 {
		return []Result{{Name: "concurrency", OK: true, Detail: "no active session locks"}}
	}

	results := make([]Result, 0, len(metrics))
	for name, m := range metrics {
		detail := fmt.Sprintf("contention: %d, max_wait: %s, total_hold: %s",
			m.ContentionCount,
			m.MaxWaitTime.Round(time.Millisecond),
			m.TotalHoldTime.Round(time.Millisecond))

		results = append(results, Result{
			Name:   "lock: " + name,
			OK:     true, // advisory
			Detail: detail,
		})
	}
	return results
}

// vendorDirFn returns the path to check for a stale vendor/ directory. It is a
// package-private seam so tests can point it at a temp directory instead of the
// real working directory. It defaults to "vendor" (relative to the process CWD).
//
//nolint:gochecknoglobals // Hook for testability; mirrors livenessStatFn seam.
var vendorDirFn = func() string { return "vendor" }

// checkVendorDir warns when a vendor/ directory is present in the working tree.
//
// B-001 footgun: gobot does NOT vendor as policy (vendor/ is gitignored and CI
// builds with -mod=readonly straight from go.mod). But Go's default build mode is
// implicit -mod=vendor whenever a vendor/ directory exists, so a leftover, stale
// vendor/ tree silently shadows go.mod — a developer's plain `go build`/`go test`
// links the old, possibly-vulnerable pinned versions instead of the go.mod-resolved
// ones, diverging from CI. This advisory check surfaces that footgun. The fix is to
// delete the local vendor/ directory (a local-only action; vendor/ is gitignored,
// so nothing is committed). See docs/security.md ("Dependency & Vendoring Policy").
func checkVendorDir() Result {
	path := vendorDirFn()
	info, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return Result{Name: "vendor policy", OK: true, Detail: "no vendor/ directory (correct: gobot does not vendor)"}
		}
		return Result{
			Name:        "vendor policy",
			OK:          false,
			Detail:      fmt.Sprintf("cannot stat %s: %v", path, err),
			Remediation: "Check permissions on the working directory.",
		}
	}
	if !info.IsDir() {
		return Result{Name: "vendor policy", OK: true, Detail: fmt.Sprintf("%s is a file, not a vendor tree", path)}
	}
	return Result{
		Name:        "vendor policy",
		OK:          false,
		Detail:      "vendor/ directory present; gobot does not vendor — a stale vendor/ silently shadows go.mod (default -mod=vendor) and diverges from CI",
		Remediation: "Delete the local vendor/ directory (it is gitignored). Do not run 'go mod vendor'; rely on the module cache + go.mod. See docs/security.md.",
	}
}

// livenessStatFn is the stat function used by checkLivenessStaleness. It is a
// package-private seam so tests can deterministically inject a stat error on
// any OS (Windows file-permission tricks via chmod do not work reliably).
//
//nolint:gochecknoglobals // Hook for testability; mirrors internal/app userHomeDir seam.
var livenessStatFn = os.Stat

// checkLivenessStaleness reports whether the heartbeat LIVENESS file at
// {StorageRoot}/LIVENESS has gone stale. The heartbeat writes this file on every
// tick; if its mtime is older than 2× the configured heartbeat interval, the
// heartbeat goroutine is likely stalled (deadlock, panic, or runtime hang). This
// surfaces the stall as a doctor warning instead of waiting for external Telegram
// alerting. It is advisory (non-critical).
//
// A missing file is treated as OK: on a cold start or fresh restart the heartbeat
// has not written LIVENESS yet, so there is no staleness to report.
func checkLivenessStaleness(cfg *config.Config) Result {
	livenessPath := filepath.Join(cfg.StorageRoot(), "LIVENESS")

	info, err := livenessStatFn(livenessPath)
	if err != nil {
		if os.IsNotExist(err) {
			return Result{
				Name:   "liveness staleness",
				OK:     true,
				Detail: "no LIVENESS file yet (cold start)",
			}
		}
		return Result{
			Name:        "liveness staleness",
			OK:          false,
			Detail:      fmt.Sprintf("cannot stat %s: %v", livenessPath, err),
			Remediation: "Check permissions on the storage root so gobot can read the LIVENESS heartbeat file.",
		}
	}

	threshold := 2 * cfg.HeartbeatInterval()
	age := time.Since(info.ModTime())
	if age > threshold {
		return Result{
			Name:        "liveness staleness",
			OK:          false,
			Detail:      fmt.Sprintf("LIVENESS last updated %s ago, threshold is %s", age.Round(time.Second), threshold),
			Remediation: "The heartbeat may be stalled; check gobot logs for a hung or panicked heartbeat goroutine and restart if needed.",
		}
	}

	return Result{
		Name:   "liveness staleness",
		OK:     true,
		Detail: fmt.Sprintf("LIVENESS updated %s ago (threshold %s)", age.Round(time.Second), threshold),
	}
}
