package doctor

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/allthingscode/gobot/internal/config"
)

type startupMarker struct {
	Version    int       `json:"version"`
	ReadyAt    time.Time `json:"ready_at"`
	DurationMS int64     `json:"duration_ms"`
}

func checkStartupTime(cfg *config.Config) Result {
	marker, err := readStartupMarker(cfg.StorageRoot())
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return Result{Name: "startup time", OK: true, Detail: "not recorded yet"}
		}
		return Result{
			Name:        "startup time",
			OK:          false,
			Detail:      err.Error(),
			Remediation: "Restart gobot once to refresh workspace/startup.json.",
		}
	}

	return Result{
		Name:   "startup time",
		OK:     true,
		Detail: fmt.Sprintf("%d ms at %s", marker.DurationMS, marker.ReadyAt.Format(time.RFC3339)),
	}
}

func readStartupMarker(storageRoot string) (startupMarker, error) {
	path := startupMarkerPath(storageRoot)
	data, err := os.ReadFile(path)
	if err != nil {
		return startupMarker{}, fmt.Errorf("read %s: %w", path, err)
	}

	var marker startupMarker
	if err := json.Unmarshal(data, &marker); err != nil {
		return startupMarker{}, fmt.Errorf("invalid startup marker %s: %w", path, err)
	}
	if marker.ReadyAt.IsZero() || marker.DurationMS < 0 {
		return startupMarker{}, fmt.Errorf("invalid startup marker %s: missing ready_at or duration_ms", path)
	}
	return marker, nil
}

func startupMarkerPath(storageRoot string) string {
	return filepath.Join(storageRoot, "workspace", "startup.json")
}
