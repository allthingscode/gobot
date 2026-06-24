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
