//nolint:testpackage // exercises unexported startup marker helpers
package app

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/config"
)

//nolint:paralleltest // mutates the package-global default logger
func TestRecordStartupReady_LogsAndWritesMarker(t *testing.T) {
	oldLogger := slog.Default()
	t.Cleanup(func() { slog.SetDefault(oldLogger) })

	var buf bytes.Buffer
	slog.SetDefault(slog.New(slog.NewTextHandler(&buf, nil)))

	root := t.TempDir()
	cfg := &config.Config{Runtime: config.RuntimeConfig{StorageRoot: root}}
	cfg.Gateway.Enabled = true
	cfg.Gateway.WebAddr = "127.0.0.1:8080"

	start := time.Date(2026, 7, 7, 12, 0, 0, 0, time.UTC)
	ready := start.Add(1500 * time.Millisecond)
	recordStartupReady(cfg, start, ready)

	logged := buf.String()
	for _, want := range []string{
		"gobot: startup ready",
		"startup_ms=1500",
		"gateway_enabled=true",
		"dashboard_enabled=true",
	} {
		if !strings.Contains(logged, want) {
			t.Fatalf("startup log missing %q: %s", want, logged)
		}
	}

	data, err := os.ReadFile(filepath.Join(root, "workspace", "startup.json"))
	if err != nil {
		t.Fatalf("read startup marker: %v", err)
	}
	var marker startupMarker
	if err := json.Unmarshal(data, &marker); err != nil {
		t.Fatalf("unmarshal startup marker: %v", err)
	}
	if marker.Version != startupMarkerVersion {
		t.Fatalf("Version = %d, want %d", marker.Version, startupMarkerVersion)
	}
	if marker.DurationMS != 1500 {
		t.Fatalf("DurationMS = %d, want 1500", marker.DurationMS)
	}
	if !marker.ReadyAt.Equal(ready) {
		t.Fatalf("ReadyAt = %s, want %s", marker.ReadyAt, ready)
	}
}

func TestWriteStartupMarker_ClampsNegativeDurationAtCallSite(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	cfg := &config.Config{Runtime: config.RuntimeConfig{StorageRoot: root}}
	start := time.Date(2026, 7, 7, 12, 0, 1, 0, time.UTC)
	ready := start.Add(-time.Second)

	recordStartupReady(cfg, start, ready)

	data, err := os.ReadFile(filepath.Join(root, "workspace", "startup.json"))
	if err != nil {
		t.Fatalf("read startup marker: %v", err)
	}
	var marker startupMarker
	if err := json.Unmarshal(data, &marker); err != nil {
		t.Fatalf("unmarshal startup marker: %v", err)
	}
	if marker.DurationMS != 0 {
		t.Fatalf("DurationMS = %d, want 0", marker.DurationMS)
	}
}

//nolint:paralleltest // mutates the package-global default logger
func TestRecordStartupReady_LogsMarkerWriteFailure(t *testing.T) {
	oldLogger := slog.Default()
	t.Cleanup(func() { slog.SetDefault(oldLogger) })

	var buf bytes.Buffer
	slog.SetDefault(slog.New(slog.NewTextHandler(&buf, nil)))

	rootFile := filepath.Join(t.TempDir(), "storage-root-is-file")
	if err := os.WriteFile(rootFile, []byte("not a directory"), 0o600); err != nil {
		t.Fatalf("write root file: %v", err)
	}
	cfg := &config.Config{Runtime: config.RuntimeConfig{StorageRoot: rootFile}}

	now := time.Date(2026, 7, 7, 12, 0, 0, 0, time.UTC)
	recordStartupReady(cfg, now, now)

	logged := buf.String()
	if !strings.Contains(logged, "gobot: failed to persist startup time") {
		t.Fatalf("startup marker failure log missing: %s", logged)
	}
}
