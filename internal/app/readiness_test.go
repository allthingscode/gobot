//nolint:testpackage // co-located with the package app internal test suite
package app

import (
	"context"
	"net"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/config"
)

// TestReadiness_Transitions covers the latch states and the one-shot Ready()
// channel (C-324).
func TestReadiness_Transitions(t *testing.T) {
	t.Parallel()
	r := NewReadiness()

	if r.IsReady() {
		t.Fatal("a new latch must start not-ready")
	}
	select {
	case <-r.Ready():
		t.Fatal("Ready() must not be closed before SetReady")
	default:
	}

	r.SetReady()
	if !r.IsReady() {
		t.Fatal("expected ready after SetReady")
	}
	select {
	case <-r.Ready():
	default:
		t.Fatal("Ready() must be closed after SetReady")
	}

	r.SetNotReady()
	if r.IsReady() {
		t.Fatal("expected not-ready after SetNotReady")
	}
	// Ready() is one-shot: it stays closed after the first SetReady.
	select {
	case <-r.Ready():
	default:
		t.Fatal("Ready() must remain closed after the first SetReady")
	}
}

// TestStartGateway_SetsReadinessOnBind covers AC2: the latch flips ready only
// after the gateway listener actually binds.
func TestStartGateway_SetsReadinessOnBind(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	cfg.Gateway.Enabled = true
	cfg.Gateway.Host = "127.0.0.1"
	cfg.Gateway.Port = 0 // ephemeral: bind whatever is free

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var wg sync.WaitGroup
	readiness := NewReadiness()

	StartGateway(ctx, cfg, nil, nil, nil, nil, &wg, nil, readiness)

	select {
	case <-readiness.Ready():
	case <-time.After(2 * time.Second):
		t.Fatal("gateway did not signal readiness after binding")
	}
	if !readiness.IsReady() {
		t.Error("expected ready==true once bound")
	}

	cancel()
	wg.Wait()
}

// TestStartGateway_BindFailure_LeavesNotReady covers AC4: a bind failure never
// marks the process ready and still propagates via the C-321 startErr path.
func TestStartGateway_BindFailure_LeavesNotReady(t *testing.T) {
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
	readiness := NewReadiness()

	StartGateway(ctx, cfg, nil, nil, nil, nil, &wg, startErr, readiness)

	select {
	case <-startErr:
		// expected: bind failed on the occupied port
	case <-time.After(2 * time.Second):
		t.Fatal("expected a startup failure on the occupied port")
	}

	if readiness.IsReady() {
		t.Error("readiness must not be set when the listener fails to bind")
	}
	select {
	case <-readiness.Ready():
		t.Error("Ready() must not close on a bind failure")
	default:
	}

	cancel()
	wg.Wait()
}
