//nolint:testpackage // requires unexported waitForShutdown/reportStartupFailure
package app

import (
	"context"
	"errors"
	"net"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/config"
)

// AC2/AC3: a critical subsystem startup error makes waitForShutdown return a
// non-nil error (which propagates to a non-zero process exit) and triggers
// shutdown of the rest via cancel.
func TestWaitForShutdown_ReturnsSubsystemError(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	canceled := false
	spy := func() { canceled = true; cancel() }

	startErr := make(chan error, 1)
	wantErr := errors.New("gateway: listen tcp :8080: bind: address already in use")
	startErr <- wantErr

	var wg sync.WaitGroup
	err := waitForShutdown(ctx, spy, &wg, startErr)
	if err == nil || !strings.Contains(err.Error(), "address already in use") {
		t.Fatalf("expected subsystem error returned, got %v", err)
	}
	if !canceled {
		t.Error("expected context cancel to be triggered on subsystem failure")
	}
}

// AC4: graceful shutdown (context cancellation / signal) returns nil even when
// no subsystem error is present.
func TestWaitForShutdown_GracefulReturnsNil(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // graceful: context already canceled

	var wg sync.WaitGroup
	if err := waitForShutdown(ctx, cancel, &wg, make(chan error, 1)); err != nil {
		t.Errorf("graceful shutdown must return nil, got %v", err)
	}
}

// AC4/AC5: reportStartupFailure drops the error when the context is already
// canceled (graceful shutdown is not a failure), and the send is non-blocking
// (full buffer and nil channel must not block).
func TestReportStartupFailure(t *testing.T) {
	t.Parallel()

	// Live context, room in buffer: error is forwarded.
	live := make(chan error, 1)
	reportStartupFailure(context.Background(), live, "gateway", errors.New("boom"))
	select {
	case err := <-live:
		if !strings.Contains(err.Error(), "gateway: boom") {
			t.Errorf("expected wrapped subsystem error, got %v", err)
		}
	default:
		t.Error("expected error to be forwarded on a live context")
	}

	// Canceled context: graceful, error dropped.
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	dropped := make(chan error, 1)
	reportStartupFailure(ctx, dropped, "gateway", errors.New("boom"))
	if len(dropped) != 0 {
		t.Error("expected error to be dropped on a canceled context")
	}

	// Non-blocking: full buffer and nil channel must not block.
	full := make(chan error, 1)
	full <- errors.New("first")
	reportStartupFailure(context.Background(), full, "gateway", errors.New("second"))
	reportStartupFailure(context.Background(), nil, "gateway", errors.New("nil-chan"))
}

// AC3 (realistic): a gateway whose port is already bound reports a startup
// failure on startErr rather than dying silently in the goroutine.
func TestStartGateway_PortConflict_ReportsStartupFailure(t *testing.T) {
	t.Parallel()
	var lc net.ListenConfig
	occupied, err := lc.Listen(context.Background(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("occupy port: %v", err)
	}
	defer func() { _ = occupied.Close() }()
	host, portStr, err := net.SplitHostPort(occupied.Addr().String())
	if err != nil {
		t.Fatalf("split host/port: %v", err)
	}
	port, _ := strconv.Atoi(portStr)

	cfg := &config.Config{}
	cfg.Gateway.Enabled = true
	cfg.Gateway.Host = host
	cfg.Gateway.Port = port

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	startErr := make(chan error, 1)
	var wg sync.WaitGroup

	StartGateway(ctx, cfg, nil, nil, nil, nil, &wg, startErr)

	select {
	case got := <-startErr:
		if !strings.Contains(got.Error(), "gateway") {
			t.Errorf("expected gateway-identified startup error, got %v", got)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("expected a startup failure on the occupied port, got none")
	}
	cancel()
	wg.Wait()
}
