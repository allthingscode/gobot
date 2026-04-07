// Package gateway provides an HTTP gateway for interacting with the gobot agent.
package gateway

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/allthingscode/gobot/internal/bot"
	"github.com/allthingscode/gobot/internal/config"
)

// Server is an HTTP gateway that dispatches requests to a bot.Handler.
type Server struct {
	cfg     config.GatewayConfig
	handler bot.Handler
}

// NewServer creates a new Gateway server.
func NewServer(cfg config.GatewayConfig, handler bot.Handler) *Server {
	return &Server{
		cfg:     cfg,
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

	addr := fmt.Sprintf("%s:%d", s.cfg.Host, s.cfg.Port)
	srv := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()

	slog.Info("gateway: starting server", "addr", addr)
	if err := srv.ListenAndServe(); err != http.ErrServerClosed {
		return err
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
