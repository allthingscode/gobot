package dashboard

import (
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"time"
)

//go:embed static/index.html
var staticFS embed.FS

// Server is an HTTP server that serves the dashboard and SSE log stream.
type Server struct {
	hub       *Hub
	addr      string
	authToken string
}

// NewServer creates a new dashboard server. When authToken is non-empty, all routes
// require a matching token; when empty, callers are responsible for binding to a
// loopback interface (see app.StartDashboard) so the stream is never exposed unauthenticated.
func NewServer(hub *Hub, addr, authToken string) *Server {
	return &Server{
		hub:       hub,
		addr:      addr,
		authToken: authToken,
	}
}

// handler builds the full request handler: the route mux wrapped in token auth.
func (s *Server) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/", s.handleIndex)
	mux.HandleFunc("/events", s.handleEvents)
	return authMiddleware(s.authToken, mux)
}

// ListenAndServe starts the dashboard server and blocks until the context is cancelled.
func (s *Server) ListenAndServe(ctx context.Context) error {
	srv := &http.Server{
		Addr:              s.addr,
		Handler:           s.handler(),
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

// authMiddleware guards the dashboard with token-based auth, mirroring the gateway
// dashboard pattern (internal/gateway/dash.AuthMiddleware). It is reimplemented here
// rather than imported because internal/gateway/dash imports this package, so importing
// it back would create a cycle. A token may be supplied via the
// "Authorization: Bearer <token>" header, a "token" query parameter, or a "gobot_token"
// cookie. When token is empty, requests are allowed and the caller is expected to bind
// the server to a loopback interface only.
func authMiddleware(token string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if token == "" {
			next.ServeHTTP(w, r)
			return
		}

		provided := ""
		if authHeader := r.Header.Get("Authorization"); strings.HasPrefix(authHeader, "Bearer ") {
			provided = strings.TrimPrefix(authHeader, "Bearer ")
		} else {
			provided = r.URL.Query().Get("token")
		}

		if provided != token {
			if cookie, err := r.Cookie("gobot_token"); err == nil {
				provided = cookie.Value
			}
		}

		if provided != token {
			slog.Warn("dashboard: unauthorized access attempt", "remote_addr", r.RemoteAddr) //nolint:gosec // G706: remote_addr is safe to log
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}

		next.ServeHTTP(w, r)
	})
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
