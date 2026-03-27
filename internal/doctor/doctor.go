// Package doctor implements the gobot health check (equivalent of strategic_doctor.py).
package doctor

import (
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"time"

	"github.com/allthingscode/gobot/internal/config"
)

type result struct {
	name   string
	ok     bool
	detail string
}

// Run performs all health checks and prints a report. Returns non-nil if any check fails.
func Run(cfg *config.Config) error {
	start := time.Now()
	checks := []result{
		checkStorageRoot(cfg),
		checkWorkspace(cfg),
		checkLogs(cfg),
		checkAPIKey(cfg),
	}

	fmt.Println("gobot doctor")
	fmt.Println("============")

	anyFail := false
	for _, c := range checks {
		icon := "OK "
		if !c.ok {
			icon = "ERR"
			anyFail = true
		}
		fmt.Printf("  [%s] %s", icon, c.name)
		if c.detail != "" {
			fmt.Printf(" — %s", c.detail)
		}
		fmt.Println()
	}

	fmt.Printf("\n%d checks in %s\n", len(checks), time.Since(start).Round(time.Millisecond))

	if anyFail {
		return fmt.Errorf("one or more health checks failed")
	}
	return nil
}

func checkStorageRoot(cfg *config.Config) result {
	root := cfg.StorageRoot()
	info, err := os.Stat(root)
	if err != nil {
		return result{"storage root exists", false, fmt.Sprintf("%s: %v", root, err)}
	}
	if !info.IsDir() {
		return result{"storage root exists", false, fmt.Sprintf("%s is not a directory", root)}
	}
	return result{"storage root exists", true, root}
}

func checkWorkspace(cfg *config.Config) result {
	ws := filepath.Join(cfg.StorageRoot(), "workspace")
	// Attempt a temp-file write to verify write access
	tmp, err := os.CreateTemp(ws, "gobot-doctor-*")
	if err != nil {
		return result{"workspace writable", false, fmt.Sprintf("%s: %v", ws, err)}
	}
	tmp.Close()
	os.Remove(tmp.Name())
	return result{"workspace writable", true, ws}
}

func checkLogs(cfg *config.Config) result {
	logs := filepath.Join(cfg.StorageRoot(), "logs")
	if err := os.MkdirAll(logs, 0o755); err != nil {
		return result{"logs directory", false, fmt.Sprintf("%v", err)}
	}
	return result{"logs directory", true, logs}
}

func checkAPIKey(cfg *config.Config) result {
	key := cfg.GeminiAPIKey()
	if key == "" {
		// Fall back to env var
		key = os.Getenv("GOOGLE_API_KEY")
	}
	if key == "" {
		return result{"gemini api key", false, "not found in config or GOOGLE_API_KEY env"}
	}
	// Mask key in output
	masked := key[:4] + "..." + key[len(key)-4:]
	slog.Debug("api key found", "masked", masked)
	return result{"gemini api key", true, masked}
}
