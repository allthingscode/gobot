package app

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/config"
)

func TestLiveProbesList_Coverage(t *testing.T) {
	probes := LiveProbesList()
	if probes == nil {
		t.Fatal("probes is nil")
	}
}

func TestRunAgent_InitSequence_Coverage(t *testing.T) {
	tmpDir := t.TempDir()
	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = tmpDir
	cfg.Providers.Gemini.APIKey = "test"
	cfg.Strategic.UserChatID = 12345

	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()

	// Use a mock log path to avoid locking gobot.log in the temp dir if possible,
	// or just accept that cleanup might fail on Windows.
	SetupLogging(cfg, nil)
	_, _ = SetupOTel(ctx, cfg)
}

func TestStartDashboard_Coverage(t *testing.T) {
	var wg sync.WaitGroup
	// Give more time for the server to start/stop
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	StartDashboard(ctx, "127.0.0.1:0", nil, &wg)
	
	// Wait a bit to ensure it actually starts
	time.Sleep(20 * time.Millisecond)
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
	SetupConsolidator(cfg, stack, nil, nil, nil, nil)
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
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()

	StartHeartbeat(ctx, cfg, "token", &wg)
	time.Sleep(10 * time.Millisecond)
	cancel()
	wg.Wait()
}

func TestStartGateway_Coverage(t *testing.T) {
	cfg := &config.Config{}
	cfg.Gateway.Enabled = true
	cfg.Gateway.WebAddr = "127.0.0.1:0"
	var wg sync.WaitGroup
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()

	StartGateway(ctx, cfg, nil, nil, nil, &wg)
	time.Sleep(10 * time.Millisecond)
	cancel()
	wg.Wait()
}

func TestRunIdempotencyCleanup_Coverage(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 1*time.Millisecond)
	cancel()
	RunIdempotencyCleanup(ctx, nil, 1*time.Hour)
}
