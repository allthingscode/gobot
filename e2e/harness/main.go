//go:build e2e

// Command harness boots a standalone instance of the dashboard server for
// Playwright end-to-end tests. It serves the embedded dashboard UI and an SSE
// log stream seeded with deterministic sample entries, plus a periodic live
// "heartbeat" entry so streaming behaviour can be asserted. The e2e build tag
// keeps it out of `go build ./...` and lint runs.
package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"time"

	"github.com/allthingscode/gobot/internal/dashboard"
)

func main() {
	addr := os.Getenv("DASHBOARD_E2E_ADDR")
	if addr == "" {
		addr = "127.0.0.1:8099"
	}

	hub := dashboard.NewHub(1000)
	seed(hub)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	go func() {
		t := time.NewTicker(time.Second)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				hub.Emit(&dashboard.LogEntry{
					Timestamp: time.Now(),
					Level:     "INFO",
					Message:   "heartbeat",
				})
			}
		}
	}()

	srv := dashboard.NewServer(hub, addr, "")
	log.Printf("dashboard e2e harness listening on http://%s", addr)
	if err := srv.ListenAndServe(ctx); err != nil {
		log.Fatal(err)
	}
}

func seed(hub *dashboard.Hub) {
	now := time.Now()
	for _, e := range []*dashboard.LogEntry{
		{Timestamp: now, Level: "INFO", Message: "gobot started", Fields: map[string]any{"version": "e2e"}},
		{Timestamp: now, Level: "WARN", Message: "rate limit approaching"},
		{Timestamp: now, Level: "ERROR", Message: "example error for tests"},
		{Timestamp: now, Level: "DEBUG", Message: "verbose detail"},
	} {
		hub.Emit(e)
	}
}
