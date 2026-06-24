package app

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"sync"
	"time"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
	agentctx "github.com/allthingscode/gobot/internal/context"
	"github.com/allthingscode/gobot/internal/dashboard"
	"github.com/allthingscode/gobot/internal/doctor"
	"github.com/allthingscode/gobot/internal/gateway"
	"github.com/allthingscode/gobot/internal/gateway/dash"
	"github.com/allthingscode/gobot/internal/memory"
	"github.com/allthingscode/gobot/internal/observability"
	"github.com/allthingscode/gobot/internal/reporter"
)

// StartDashboard starts the F-111 SSE dashboard server in a separate goroutine.
// When authToken is empty the dashboard has no authentication, so it is bound to a
// loopback interface only and a warning is logged; remote access requires a configured token.
func StartDashboard(ctx context.Context, addr, authToken string, hub *dashboard.Hub, wg *sync.WaitGroup, startErr chan<- error) {
	if authToken == "" {
		bind := dashboardBindAddr(addr, authToken)
		if bind != addr {
			slog.Warn("dashboard: no auth token configured; binding to loopback only, remote access disabled",
				"requested", addr, "bind", bind)
			addr = bind
		} else {
			slog.Warn("dashboard: no auth token configured; serving unauthenticated on loopback interface", "bind", addr)
		}
	}
	srv := dashboard.NewServer(hub, addr, authToken)
	wg.Add(1)
	go func() {
		defer RecoverWithStack("dashboard")
		defer wg.Done()
		if err := srv.ListenAndServe(ctx); err != nil {
			slog.Error("dashboard: failure", "err", err)
			reportStartupFailure(ctx, startErr, "dashboard", err)
		}
	}()
}

// dashboardBindAddr returns the address the dashboard should bind to. When no auth token
// is configured, a non-loopback host is forced to 127.0.0.1 so an unauthenticated stream
// is never exposed on a LAN-reachable interface. The port is preserved.
func dashboardBindAddr(addr, token string) string {
	if token != "" {
		return addr
	}
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return addr
	}
	if isLoopbackHost(host) {
		return addr
	}
	return net.JoinHostPort("127.0.0.1", port)
}

func isLoopbackHost(host string) bool {
	// An empty host means "all interfaces" (e.g. ":8080") - NOT loopback.
	if host == "" {
		return false
	}
	if host == "localhost" {
		return true
	}
	if ip := net.ParseIP(host); ip != nil {
		return ip.IsLoopback()
	}
	return false
}

// StartGateway starts the HTTP gateway server in a separate goroutine.
func StartGateway(ctx context.Context, cfg *config.Config, store agent.CheckpointStore, memStore *memory.MemoryStore, gateHandler bot.Handler, hub *dashboard.Hub, wg *sync.WaitGroup, startErr chan<- error, readiness *Readiness) {
	mgr, _ := store.(*agentctx.CheckpointManager)
	res := dash.Resources{
		Config:      cfg,
		Checkpoints: mgr,
		Memory:      memStore,
		Cron:        NewSchedulerCronProvider(cfg.StorageRoot()),
		Version:     Version,
	}
	if hub != nil {
		res.Hub = hub
	}
	srv := gateway.NewServer(cfg.Gateway, gateHandler, res)
	if readiness != nil {
		// /ready reads the live latch; the listener marks ready once bound.
		srv.SetReadiness(readiness.IsReady, readiness.SetReady)
	}
	wg.Add(1)
	go func() {
		defer RecoverWithStack("gateway")
		defer wg.Done()
		if err := srv.ListenAndServe(ctx); err != nil {
			slog.Error("gateway: failure", "err", err)
			reportStartupFailure(ctx, startErr, "gateway", err)
		}
	}()
}

// RunIdempotencyCleanup runs periodic background cleanup of expired idempotency keys.
func RunIdempotencyCleanup(ctx context.Context, store *agentctx.IdempotencyStore, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			cleaned, err := store.CleanupExpired(ctx)
			if err != nil {
				slog.Error("run: idempotency cleanup failed", "err", err)
				continue
			}
			if cleaned > 0 {
				slog.Info("run: cleaned up expired idempotency keys", "count", cleaned)
			}
		}
	}
}

// StartTelegramBot initializes and starts the Telegram polling bot.
func StartTelegramBot(ctx context.Context, api bot.API, gateHandler bot.Handler, tracer *observability.DispatchTracer, wg *sync.WaitGroup) *bot.Bot {
	if api == nil {
		slog.Error("gobot: telegram bot initialization failed, API is nil")
		return nil
	}
	b := bot.New(api, gateHandler)
	if tracer != nil {
		b.SetTracer(tracer)
	}
	wg.Add(1)
	go func() {
		defer RecoverWithStack("telegram-bot")
		defer wg.Done()
		if err := b.Run(ctx); err != nil && !errors.Is(err, context.Canceled) {
			slog.Error("telegram: bot runtime failure", "err", err)
		}
	}()
	slog.Info("gobot: telegram bot started")
	return b
}

// StartCron starts the modular cron scheduler in a separate goroutine.
func StartCron(ctx context.Context, cfg *config.Config, stack *AgentStack, b *bot.Bot, tmgr *reporter.TemplateManager, tracer *observability.DispatchTracer, wg *sync.WaitGroup) {
	if !cfg.Cron.Enabled {
		return
	}
	mgr := stack.NewSessionManager(cfg, nil, tracer)
	cd := NewCronDispatcher(cfg, mgr, stack, b, tmgr)
	wg.Add(1)
	go func() {
		defer RecoverWithStack("cron-dispatcher")
		defer wg.Done()
		cd.Run(ctx)
	}()
	slog.Info("gobot: cron dispatcher started")
}

// alertSenderFromAPI adapts the concrete *TgAPI to the AlertSender interface while
// preserving a true nil interface when no API is available. Assigning a nil *TgAPI
// directly to an AlertSender would yield a non-nil interface wrapping a nil pointer,
// defeating the runner's `sender == nil` guard and panicking on Send.
func alertSenderFromAPI(api *TgAPI) AlertSender {
	if api == nil {
		return nil
	}
	return api
}

// StartHeartbeat starts the periodic health check runner, injecting the alert sender so
// probe failures can page the operator.
func StartHeartbeat(ctx context.Context, cfg *config.Config, token string, sender AlertSender, wg *sync.WaitGroup) {
	if !cfg.Heartbeat.Enabled {
		return
	}
	hb := NewHeartbeatRunner(cfg, token, sender)
	wg.Add(1)
	go func() {
		defer RecoverWithStack("heartbeat-runner")
		defer wg.Done()
		hb.Run(ctx)
	}()
	slog.Info("gobot: heartbeat runner started")
}

// DrainGoroutines waits for all registered background tasks to complete or times out.
func DrainGoroutines(wg *sync.WaitGroup, timeout time.Duration) {
	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()
	select {
	case <-done:
		slog.Info("gobot: drain complete, proceeding to shutdown")
	case <-time.After(timeout):
		slog.Warn("gobot: drain timed out forcing exit", "timeout", timeout)
	}
}

// LiveProbes returns health check probes that interact with live APIs.
func LiveProbes() *doctor.Probes {
	return LiveProbesList()
}
