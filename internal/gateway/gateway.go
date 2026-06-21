// Package gateway provides an HTTP gateway for interacting with the gobot agent.
package gateway

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"time"

	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/gateway/dash"
)

// Server is an HTTP gateway that dispatches requests to a bot.Handler.
type Server struct {
	cfg     config.GatewayConfig
	dashRes dash.Resources
	handler bot.Handler

	// readyFn reports process readiness for the /ready handler. When nil, the
	// server is considered ready as soon as it is serving. onBound is invoked
	// once the listener has successfully bound (the readiness signal). Both are
	// optional and wired by the caller via SetReadiness.
	readyFn func() bool
	onBound func()
}

// SetReadiness wires the readiness probe (readyFn, read by /ready) and the bind
// signal (onBound, invoked once the listener binds). Call before ListenAndServe.
func (s *Server) SetReadiness(readyFn func() bool, onBound func()) {
	s.readyFn = readyFn
	s.onBound = onBound
}

// NewServer creates a new Gateway server.
func NewServer(cfg config.GatewayConfig, handler bot.Handler, dashRes dash.Resources) *Server {
	return &Server{
		cfg:     cfg,
		dashRes: dashRes,
		handler: handler,
	}
}

// InboundRequest mirrors bot.InboundMessage for HTTP transport.
type InboundRequest struct {
	SessionKey string `json:"session_key"`
	Text       string `json:"text"`
}

// OutboundResponse is the JSON response for a gateway request.
type OutboundResponse struct {
	Reply string `json:"reply,omitempty"`
	Error string `json:"error,omitempty"`
}

// ListenAndServe starts the HTTP server and blocks until ctx is cancelled.
func (s *Server) ListenAndServe(ctx context.Context) error {
	mux := http.NewServeMux()
	mux.HandleFunc("/chat", s.handleChat)
	mux.HandleFunc("/health", s.handleHealth)
	mux.HandleFunc("/ready", s.handleReady)

	// Dashboard routes with authentication
	if s.cfg.DashboardEnabled {
		dashHandler := dash.NewHandler(s.dashRes)
		mux.Handle("/dash/", dash.AuthMiddleware(s.cfg.AuthToken, dashHandler))
		slog.Info("gateway: dashboard enabled", "path", "/dash/")
	}

	addr := fmt.Sprintf("%s:%d", s.cfg.Host, s.cfg.Port)
	srv := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	// Bind first (split from serving) so we can signal readiness only once the
	// listener is actually accepting connections; a bind failure is returned to
	// the caller (and never marks the process ready).
	var lc net.ListenConfig
	ln, err := lc.Listen(ctx, "tcp", addr)
	if err != nil {
		return fmt.Errorf("listen %s: %w", addr, err)
	}
	if s.onBound != nil {
		s.onBound()
	}

	go func() {
		<-ctx.Done()
		// Use WithoutCancel to detach from the cancelled parent context
		// while preserving context values, then add a shutdown timeout.
		shutdownCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()

	slog.Info("gateway: starting server", "addr", addr)
	if err := srv.Serve(ln); err != http.ErrServerClosed {
		return fmt.Errorf("serve: %w", err)
	}
	return nil
}

func (s *Server) handleChat(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req InboundRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		slog.Warn("gateway: invalid request body", "err", err)
		http.Error(w, "Invalid JSON", http.StatusBadRequest)
		return
	}

	if req.SessionKey == "" {
		req.SessionKey = "gateway:default"
	}

	slog.Info("gateway: request received", "session", req.SessionKey, "text", req.Text)

	// Dispatch to the shared agent handler.
	// We wrap the inbound request into a bot.InboundMessage.
	msg := bot.InboundMessage{
		Text: req.Text,
	}

	reply, err := s.handler.Handle(r.Context(), req.SessionKey, msg)

	resp := OutboundResponse{Reply: reply}
	if err != nil {
		slog.Error("gateway: handler error", "session", req.SessionKey, "err", err)
		resp.Error = err.Error()
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("OK"))
}

// handleReady is the readiness probe, distinct from /health liveness. It reports
// 200 only while the process is ready to serve (listener bound and not shutting
// down) and 503 otherwise, so orchestration can stop routing during startup and
// the shutdown drain window. Unauthenticated, for parity with /health. When no
// readiness probe is wired, a serving process is treated as ready.
func (s *Server) handleReady(w http.ResponseWriter, _ *http.Request) {
	if s.readyFn != nil && !s.readyFn() {
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte("not ready"))
		return
	}
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ready"))
}
