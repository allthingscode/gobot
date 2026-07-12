package dash

import (
	"log/slog"
	"net/http"
	"strings"
)

// AuthMiddleware wraps a handler with basic token-based authentication.
func AuthMiddleware(token string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if token == "" {
			// If no token is configured, allow access (or we could default to blocking)
			next.ServeHTTP(w, r)
			return
		}

		// Check for token in 'Authorization: Bearer <token>' header or 'token' query param
		authHeader := r.Header.Get("Authorization")
		provided := ""
		if strings.HasPrefix(authHeader, "Bearer ") {
			provided = strings.TrimPrefix(authHeader, "Bearer ")
		} else {
			provided = r.URL.Query().Get("token")
		}

		if provided != token {
			// Also check for 'token' cookie as a fallback for browser access
			if cookie, err := r.Cookie("gobot_token"); err == nil {
				provided = cookie.Value
			}
		}

		if provided != token {
			slog.Warn("dash: unauthorized access attempt", "remote_addr", r.RemoteAddr) //nolint:gosec // G706: remote_addr is safe to log
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}

		next.ServeHTTP(w, r)
	})
}
