package doctor

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/allthingscode/gobot/internal/config"
)

func checkStorageRoot(cfg *config.Config) Result {
	root := cfg.StorageRoot()
	info, err := os.Stat(root)
	if err != nil {
		return Result{
			Name:        "storage root",
			OK:          false,
			Detail:      fmt.Sprintf("%s: %v", root, err),
			Remediation: "Create the storage directory or check GOBOT_STORAGE environment variable.",
		}
	}
	if !info.IsDir() {
		return Result{
			Name:        "storage root",
			OK:          false,
			Detail:      fmt.Sprintf("%s is not a directory", root),
			Remediation: "Ensure GOBOT_STORAGE points to a directory, not a file.",
		}
	}
	return Result{Name: "storage root", OK: true, Detail: root}
}

func checkWorkspace(cfg *config.Config) Result {
	ws := filepath.Join(cfg.StorageRoot(), "workspace")
	tmp, err := os.CreateTemp(ws, "gobot-doctor-*")
	if err != nil {
		return Result{
			Name:        "workspace writable",
			OK:          false,
			Detail:      fmt.Sprintf("%s: %v", ws, err),
			Remediation: "Ensure the workspace directory is writable by the current user.",
		}
	}
	_ = tmp.Close()
	_ = os.Remove(tmp.Name())
	return Result{Name: "workspace writable", OK: true, Detail: ws}
}

func checkLogs(cfg *config.Config) Result {
	logs := filepath.Join(cfg.StorageRoot(), "logs")
	if err := os.MkdirAll(logs, 0o755); err != nil {
		return Result{
			Name:        "logs directory",
			OK:          false,
			Detail:      fmt.Sprintf("%v", err),
			Remediation: "Create the logs directory or check parent directory permissions.",
		}
	}
	return Result{Name: "logs directory", OK: true, Detail: logs}
}

// checkJobsDir verifies the cron jobs directory exists and has .md job files.
func checkJobsDir(cfg *config.Config) Result {
	dir := filepath.Join(cfg.StorageRoot(), "workspace", "jobs")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return Result{
			Name:        "jobs directory",
			OK:          false,
			Detail:      fmt.Sprintf("%s: %v", dir, err),
			Remediation: "Create a 'jobs' directory inside your workspace.",
		}
	}
	count := 0
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(strings.ToLower(e.Name()), ".md") {
			count++
		}
	}
	if count == 0 {
		return Result{
			Name:        "jobs directory",
			OK:          true,
			Detail:      fmt.Sprintf("%s (no .md jobs)", dir),
			Remediation: "Add .md job files to the jobs directory to use cron features.",
		}
	}
	return Result{Name: "jobs directory", OK: true, Detail: fmt.Sprintf("%d job(s) in %s", count, dir)}
}

// storageSizeWarnBytes is the per-store advisory threshold. Any single named store
// (checkpoints.db total incl. WAL, audit.db total incl. WAL, vectors.db total incl.
// WAL, sessions/ dir total, logs/ dir total) that exceeds this value causes the
// result to be advisory WARN (OK=false, Critical=false). 500 MiB is chosen because
// logs/ has a hard ~250 MiB lumberjack cap, so a 500 MiB trip means a non-log store
// is unexpectedly large.
const storageSizeWarnBytes = int64(500 << 20) // 500 MiB

// storageSizeStatFn is the stat function used by checkStorageSizes for individual
// database files. It is a package-private seam so tests can inject a synthetic size
// without writing gigabyte fixtures.
//
//nolint:gochecknoglobals // Hook for testability; mirrors livenessStatFn seam.
var storageSizeStatFn = os.Stat

// fmtBytes formats n bytes: >=1 MiB as "N.N MiB", >=1 KiB as "N KiB", else "N B".
func fmtBytes(n int64) string {
	const mib = int64(1 << 20)
	const kib = int64(1 << 10)
	switch {
	case n >= mib:
		return fmt.Sprintf("%.1f MiB", float64(n)/float64(mib))
	case n >= kib:
		return fmt.Sprintf("%d KiB", n/kib)
	default:
		return fmt.Sprintf("%d B", n)
	}
}

// walToken formats a WAL size as " (+wal N)" when present and non-zero, otherwise "".
func walToken(walBytes int64) string {
	if walBytes == 0 {
		return ""
	}
	return fmt.Sprintf(" (+wal %s)", fmtBytes(walBytes))
}

// dbSize returns the on-disk size of path via storageSizeStatFn, or 0 if absent.
func dbSize(path string) (int64, error) {
	info, err := storageSizeStatFn(path)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}
		return 0, err
	}
	return info.Size(), nil
}

// collectDBSize returns the main db file size and its WAL companion via dbSize.
func collectDBSize(dbPath, walPath string) (db, wal int64, err error) {
	db, err = dbSize(dbPath)
	if err != nil {
		return 0, 0, err
	}
	wal, err = dbSize(walPath)
	if err != nil {
		return 0, 0, err
	}
	return db, wal, nil
}

// dirSize sums regular-file sizes under dir using filepath.WalkDir.
// Returns (0, 0, nil) when dir is absent.
func dirSize(dir string) (totalBytes int64, fileCount int, err error) {
	err = filepath.WalkDir(dir, func(_ string, d os.DirEntry, werr error) error {
		if werr != nil {
			if os.IsNotExist(werr) {
				return nil
			}
			return werr
		}
		if d.Type().IsRegular() {
			info, infoErr := d.Info()
			if infoErr != nil {
				return fmt.Errorf("dir entry info: %w", infoErr)
			}
			totalBytes += info.Size()
			fileCount++
		}
		return nil
	})
	if err != nil {
		return 0, 0, fmt.Errorf("walk %s: %w", dir, err)
	}
	return totalBytes, fileCount, nil
}

// checkStorageSizes reports the on-disk size of each store identified as an
// unbounded grower in R-016. The probe is read-only (os.Stat for db files,
// filepath.WalkDir for directory trees) and advisory (Critical=false).
func checkStorageSizes(cfg *config.Config) Result {
	root := cfg.StorageRoot()
	ws := filepath.Join(root, "workspace")
	mem := filepath.Join(root, "memory")

	ckptDB, ckptWAL, err := collectDBSize(filepath.Join(ws, "checkpoints.db"), filepath.Join(ws, "checkpoints.db-wal"))
	if err != nil {
		return errStorageSizeResult("checkpoints.db", err)
	}
	auditDB, auditWAL, err := collectDBSize(filepath.Join(ws, "audit.db"), filepath.Join(ws, "audit.db-wal"))
	if err != nil {
		return errStorageSizeResult("audit.db", err)
	}
	vecDB, vecWAL, err := collectDBSize(filepath.Join(mem, "vectors.db"), filepath.Join(mem, "vectors.db-wal"))
	if err != nil {
		return errStorageSizeResult("vectors.db", err)
	}

	sessBytes, sessCount, err := dirSize(filepath.Join(ws, "sessions"))
	if err != nil {
		return errStorageSizeResult("sessions/", err)
	}
	logsBytes, _, err := dirSize(filepath.Join(root, "logs"))
	if err != nil {
		return errStorageSizeResult("logs/", err)
	}

	detail := fmt.Sprintf("checkpoints %s%s, vectors %s%s, audit %s%s, sessions %s (%d files), logs %s",
		fmtBytes(ckptDB), walToken(ckptWAL),
		fmtBytes(vecDB), walToken(vecWAL),
		fmtBytes(auditDB), walToken(auditWAL),
		fmtBytes(sessBytes), sessCount,
		fmtBytes(logsBytes))

	type storeTotal struct {
		name  string
		total int64
	}
	for _, s := range []storeTotal{
		{"checkpoints.db", ckptDB + ckptWAL},
		{"audit.db", auditDB + auditWAL},
		{"vectors.db", vecDB + vecWAL},
		{"sessions/", sessBytes},
		{"logs/", logsBytes},
	} {
		if s.total > storageSizeWarnBytes {
			return Result{
				Name:        "storage sizes",
				OK:          false,
				Detail:      detail,
				Remediation: fmt.Sprintf("%s is large (%s); for checkpoints.db run 'VACUUM' or reduce turn frequency; for sessions/ check the retention cap (C-336); for logs/ check lumberjack MaxSizeMB/MaxBackups in config.json", s.name, fmtBytes(s.total)),
			}
		}
	}

	return Result{Name: "storage sizes", OK: true, Detail: detail}
}

// errStorageSizeResult returns an advisory WARN when a storage stat or walk fails.
func errStorageSizeResult(store string, err error) Result {
	return Result{
		Name:        "storage sizes",
		OK:          false,
		Detail:      fmt.Sprintf("cannot stat %s: %v", store, err),
		Remediation: fmt.Sprintf("Check permissions on the storage path for %s.", store),
	}
}
