package app

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"time"

	"github.com/allthingscode/gobot/internal/config"
)

const startupMarkerVersion = 1

type startupMarker struct {
	Version    int       `json:"version"`
	ReadyAt    time.Time `json:"ready_at"`
	DurationMS int64     `json:"duration_ms"`
}

func recordStartupReady(cfg *config.Config, startupStart, readyAt time.Time) {
	duration := readyAt.Sub(startupStart)
	if duration < 0 {
		duration = 0
	}
	durationMS := duration.Milliseconds()

	slog.Info("gobot: startup ready",
		"startup_ms", durationMS,
		"gateway_enabled", cfg.Gateway.Enabled,
		"dashboard_enabled", cfg.Gateway.WebAddr != "",
	)

	if err := writeStartupMarker(cfg.StorageRoot(), startupMarker{
		Version:    startupMarkerVersion,
		ReadyAt:    readyAt,
		DurationMS: durationMS,
	}); err != nil {
		slog.Warn("gobot: failed to persist startup time", "err", err)
	}
}

func writeStartupMarker(storageRoot string, marker startupMarker) error {
	path := startupMarkerPath(storageRoot)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create startup marker directory: %w", err)
	}

	data, err := json.MarshalIndent(marker, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal startup marker: %w", err)
	}
	data = append(data, '\n')

	if err := os.WriteFile(path, data, 0o600); err != nil {
		return fmt.Errorf("write startup marker: %w", err)
	}
	return nil
}

func startupMarkerPath(storageRoot string) string {
	return filepath.Join(storageRoot, "workspace", "startup.json")
}
