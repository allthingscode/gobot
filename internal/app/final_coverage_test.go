package app

import (
	"context"
	"net"
	"net/http"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/config"
)

const testToken = "test"
const coverageLoopback = "127.0.0.1"

func TestLiveProbesList_Coverage(t *testing.T) {
	probes := LiveProbesList()
	if probes == nil {
		t.Fatal("probes is nil")
	}
}

func TestRunAgent_InitSequence_Coverage(t *testing.T) {
	tmpDir := t.TempDir()
	cfg := &config.Config{}
	cfg.Runtime.StorageRoot = tmpDir
	cfg.Providers.Gemini.APIKey = testToken
	cfg.Runtime.UserChatID = 12345

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Use a mock log path to avoid locking gobot.log in the temp dir if possible,
	// or just accept that cleanup might fail on Windows.
	SetupLogging(cfg, nil)
	_, _ = SetupOTel(ctx, cfg)
}

func TestStartDashboard_Coverage(t *testing.T) {
	addr, _ := coverageServerAddress(t)
	ctx, cancel := context.WithCancel(context.Background())
	var wg sync.WaitGroup
	t.Cleanup(func() { cancel(); wg.Wait() })
	StartDashboard(ctx, addr, "", nil, &wg, nil)
	awaitCoverageHTTP(t, "http://"+addr+"/")
	cancel()
	wg.Wait()
}

func TestSetupGateHandler_Coverage(t *testing.T) {
	handler := &DispatchHandler{}
	_ = SetupGateHandler(nil, handler)
}

func TestSetupConsolidator_Coverage(t *testing.T) {
	cfg := &config.Config{}
	stack := &AgentStack{Runner: &AgentRunner{}}
	SetupConsolidator(context.Background(), cfg, stack, nil, nil, nil, nil)
}

func TestLiveProbes_Coverage(t *testing.T) {
	p := LiveProbes()
	if p == nil {
		t.Error("LiveProbes() returned nil")
	}
}

func TestDrainGoroutines_Coverage(t *testing.T) {
	var wg sync.WaitGroup
	DrainGoroutines(&wg, 1*time.Millisecond)
}

func TestStartHeartbeat_Coverage(t *testing.T) {
	cfg := &config.Config{}
	cfg.Heartbeat.Enabled = true
	var wg sync.WaitGroup
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(func() { cancel(); wg.Wait() })
	entered := make(chan struct{})
	startHeartbeat(ctx, cfg, "token", nil, &wg, func() { close(entered) })
	select {
	case <-entered:
	case <-time.After(30 * time.Second):
		t.Fatal("heartbeat did not enter worker")
	}
	cancel()
	wg.Wait()
}

func TestStartGateway_Coverage(t *testing.T) {
	addr, port := coverageServerAddress(t)
	cfg := &config.Config{}
	cfg.Runtime.StorageRoot = t.TempDir()
	cfg.Gateway.Enabled = true
	cfg.Gateway.Host = coverageLoopback
	cfg.Gateway.Port = port
	var wg sync.WaitGroup
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(func() { cancel(); wg.Wait() })
	readiness := NewReadiness()
	StartGateway(ctx, cfg, nil, nil, nil, nil, &wg, nil, readiness)
	select {
	case <-readiness.Ready():
	case <-time.After(30 * time.Second):
		t.Fatal("gateway did not bind")
	}
	awaitCoverageHTTP(t, "http://"+addr+"/ready")
	cancel()
	wg.Wait()
}

func TestRunIdempotencyCleanup_Coverage(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	RunIdempotencyCleanup(ctx, nil, 1*time.Hour)
}

// The server APIs accept addresses, so reserve a loopback port before starting.
func coverageServerAddress(t *testing.T) (addr string, port int) {
	t.Helper()
	var lc net.ListenConfig
	ln, err := lc.Listen(context.Background(), "tcp", net.JoinHostPort(coverageLoopback, "0"))
	if err != nil {
		t.Fatal(err)
	}
	addr = ln.Addr().String()
	_, portText, err := net.SplitHostPort(addr)
	if err != nil {
		t.Fatal(err)
	}
	port, err = strconv.Atoi(portText)
	if err != nil {
		t.Fatal(err)
	}
	if err := ln.Close(); err != nil {
		t.Fatal(err)
	}
	return addr, port
}
func awaitCoverageHTTP(t *testing.T, url string) {
	t.Helper()
	client := &http.Client{Timeout: time.Second}
	t.Cleanup(client.CloseIdleConnections)
	waitFor(t, "HTTP readiness at "+url, func() bool {
		req, err := http.NewRequestWithContext(context.Background(), http.MethodGet, url, http.NoBody)
		if err != nil {
			t.Fatal(err)
		}
		resp, err := client.Do(req)
		if err != nil {
			return false
		}
		_ = resp.Body.Close()
		return resp.StatusCode == http.StatusOK
	})
}
