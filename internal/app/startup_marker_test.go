//nolint:testpackage // exercises unexported startup marker helpers
package app

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/config"
)

const (
	startupCaseReady    = "ready"
	startupCaseCanceled = "canceled context"
)

//nolint:paralleltest // captures the default logger; all fixtures are offline
func TestPublishStartupReady(t *testing.T) {
	for _, name := range []string{startupCaseReady, "timeout", startupCaseCanceled, "ready canceled", "nil latch", "stale latch", startupDisabled, "bind"} {
		for _, existing := range []bool{false, true} {
			t.Run(fmtStartupCase(name, existing), func(t *testing.T) { testStartupPublication(t, name, existing) })
		}
	}
}

func fmtStartupCase(name string, existing bool) string {
	return name + "/existing=" + strconv.FormatBool(existing)
}

func testStartupPublication(t *testing.T, name string, existing bool) {
	t.Helper()
	cfg := &config.Config{Runtime: config.RuntimeConfig{StorageRoot: t.TempDir()}}
	cfg.Gateway.Enabled = name != startupDisabled
	previous := startupMarker{Version: startupMarkerVersion, ReadyAt: time.Now().Add(-time.Hour), DurationMS: 100}
	path := startupMarkerPath(cfg.StorageRoot())
	var before []byte
	if existing {
		if err := writeStartupMarker(cfg.StorageRoot(), previous); err != nil {
			t.Fatal(err)
		}
		var err error
		before, err = os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
	}
	var logs, banner bytes.Buffer
	oldLogger := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&logs, nil)))
	t.Cleanup(func() { slog.SetDefault(oldLogger) })
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	r := NewReadiness()
	start := time.Now().Add(-time.Second)
	r = prepareStartupReadiness(name, r, cancel)
	if name == "bind" {
		checkStartupBindFailure(t, ctx, cancel, cfg, r, start, &banner)
	} else {
		publishStartupReady(ctx, cfg, r, start, nil, &banner, 10*time.Millisecond)
	}
	data, err := os.ReadFile(path)
	if name != startupCaseReady && name != startupDisabled {
		assertFailedPublication(t, existing, before, data, err, banner.String(), logs.String())
		return
	}
	assertSuccessfulPublication(t, name, r, start, data, err, banner.String(), logs.String())
}

func assertFailedPublication(t *testing.T, existing bool, before, data []byte, err error, banner, logs string) {
	t.Helper()
	if banner != "" || strings.Contains(logs, "gobot: startup ready") || strings.Contains(logs, "startup_ms") {
		t.Fatalf("failed attempt published success: %s %s", banner, logs)
	}
	if existing {
		if err != nil || !bytes.Equal(data, before) {
			t.Fatalf("marker changed: %s %v", data, err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("failed attempt created marker: %v", err)
	}
}

func assertSuccessfulPublication(t *testing.T, name string, r *Readiness, start time.Time, data []byte, err error, banner, logs string) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
	var marker startupMarker
	if err := json.Unmarshal(data, &marker); err != nil {
		t.Fatal(err)
	}
	if marker.Version != startupMarkerVersion || marker.DurationMS < 0 || !marker.ReadyAt.After(start) {
		t.Fatalf("invalid marker: %+v", marker)
	}
	if name == startupCaseReady {
		readyAt, _ := r.ReadyAt()
		if !marker.ReadyAt.Equal(readyAt) {
			t.Fatalf("lost first ready timestamp: %s != %s", marker.ReadyAt, readyAt)
		}
	}
	assertStartupSuccessOutput(t, banner, logs)
}

func checkStartupBindFailure(t *testing.T, ctx context.Context, cancel context.CancelFunc, cfg *config.Config, r *Readiness, start time.Time, banner *bytes.Buffer) {
	t.Helper()
	var lc net.ListenConfig
	occupied, err := lc.Listen(ctx, "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = occupied.Close() })
	cfg.Gateway.Host = "127.0.0.1"
	cfg.Gateway.Port = occupied.Addr().(*net.TCPAddr).Port
	startErr := make(chan error, 1)
	var wg sync.WaitGroup
	wg.Add(1)
	go func() { defer wg.Done(); <-ctx.Done() }()
	t.Cleanup(func() { cancel(); wg.Wait() })
	StartGateway(ctx, cfg, nil, nil, nil, nil, &wg, startErr, r)
	var cause error
	select {
	case cause = <-startErr:
	case <-time.After(2 * time.Second):
		t.Fatal("gateway did not report bind error")
	}
	startErr <- cause
	publishStartupReady(ctx, cfg, r, start, nil, banner, 10*time.Millisecond)
	result := make(chan error, 1)
	go func() { result <- waitForShutdown(ctx, cancel, &wg, startErr, r) }()
	select {
	case got := <-result:
		assertStartupBindError(t, got, cause)
		if ctx.Err() == nil || r.IsReady() {
			t.Fatal("workers not canceled or readiness not cleared")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("shutdown did not drain promptly")
	}
}

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

func assertStartupBindError(t *testing.T, got, cause error) {
	t.Helper()
	var op *net.OpError
	if !errors.Is(got, cause) || !errors.As(got, &op) {
		t.Fatalf("lost bind error identity: %v", got)
	}
	if op.Op != "listen" || !strings.Contains(got.Error(), "gateway") || !strings.Contains(got.Error(), "bind") {
		t.Fatalf("lost actionable bind error: %v", got)
	}
}

func prepareStartupReadiness(name string, r *Readiness, cancel context.CancelFunc) *Readiness {
	switch name {
	case startupCaseReady, "ready canceled":
		r.SetReady()
	case "stale latch":
		r.SetReady()
		r.SetNotReady()
	case "nil latch":
		r = nil
	}
	if name == startupCaseCanceled || name == "ready canceled" || name == startupDisabled {
		cancel()
	}
	return r
}

func assertStartupSuccessOutput(t *testing.T, banner, logs string) {
	t.Helper()
	if strings.Count(banner, "gobot ready\n") != 1 || strings.Count(logs, `"msg":"gobot: startup ready"`) != 1 || !strings.Contains(logs, `"startup_ms":`) {
		t.Fatalf("missing integrated success: %s %s", banner, logs)
	}
}
