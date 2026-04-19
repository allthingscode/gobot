package dashboard

import (
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"time"
)

//go:embed static/index.html
var staticFS embed.FS

// Server is an HTTP server that serves the dashboard and SSE log stream.
type Server struct {
	hub  *Hub
	addr string
}

// NewServer creates a new dashboard server.
func NewServer(hub *Hub, addr string) *Server {
	return &Server{
		hub:  hub,
		addr: addr,
	}
}

// ListenAndServe starts the dashboard server and blocks until the context is cancelled.
func (s *Server) ListenAndServe(ctx context.Context) error {
	mux := http.NewServeMux()
	mux.HandleFunc("/", s.handleIndex)
	mux.HandleFunc("/events", s.handleEvents)

	srv := &http.Server{
		Addr:              s.addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	//nolint:gosec // background context required for graceful shutdown
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()

	slog.Info("dashboard: starting server", "addr", s.addr)
	if err := srv.ListenAndServe(); err != http.ErrServerClosed {
		return fmt.Errorf("listen and serve: %w", err)
	}
	return nil
}

func (s *Server) handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	data, err := staticFS.ReadFile("static/index.html")
	if err != nil {
		http.Error(w, "Failed to read index.html", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html")
	_, _ = w.Write(data)
}

func (s *Server) handleEvents(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "Streaming unsupported", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("Access-Control-Allow-Origin", "*")

	sub, backlog := s.hub.Subscribe()
	defer s.hub.Unsubscribe(sub)

	// Send backlog first
	for _, entry := range backlog {
		if err := sendSSE(w, flusher, entry); err != nil {
			return
		}
	}

	// Stream live entries
	for {
		select {
		case <-r.Context().Done():
			return
		case entry, ok := <-sub:
			if !ok {
				return
			}
			if err := sendSSE(w, flusher, entry); err != nil {
				return
			}
		}
	}
}

func sendSSE(w http.ResponseWriter, flusher http.Flusher, entry *LogEntry) error {
	data, err := json.Marshal(entry)
	if err != nil {
		return fmt.Errorf("marshal entry: %w", err)
	}
	if _, err := fmt.Fprintf(w, "data: %s\n\n", data); err != nil {
		return fmt.Errorf("write data: %w", err)
	}
	flusher.Flush()
	return nil
}