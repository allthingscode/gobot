//nolint:testpackage // requires unexported handler internals for testing
package dash

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/config"
)

// mockMemoryStats implements MemoryStatsProvider.
type mockMemoryStats struct {
	count int
	err   error
}

func (m *mockMemoryStats) Stats() (int, error) {
	return m.count, m.err
}

func TestDashboardHandlers(t *testing.T) {
	t.Parallel()
	h := setupDashboardHandler()
	tests := []struct {
		path   string
		status int
		body   []string
	}{
		{"/dash/", http.StatusOK, []string{"GoBot Dashboard", "test-v1", "System Overview"}},
		{"/dash/sessions", http.StatusOK, []string{"Active Sessions"}},
		{"/dash/memory", http.StatusOK, []string{"Strategic Memory", "42"}},
		{"/dash/cron", http.StatusOK, []string{"Cron Jobs"}},
		{"/dash/doctor", http.StatusOK, []string{"Doctor Diagnostics"}},
		{"/dash/doctor?partial=true", http.StatusOK, []string{"Last checked:"}},
		{"/dash/logs", http.StatusOK, []string{"System Logs"}},
		{"/dash/unknown", http.StatusFound, nil},
	}
	for _, tt := range tests {
		t.Run(tt.path, func(t *testing.T) {
			t.Parallel()
			validateDashboardResponse(t, h, tt.path, tt.status, tt.body)
		})
	}
}

func setupDashboardHandler() *Handler {
	cfg := &config.Config{}
	cfg.Gateway.DashboardEnabled = true
	res := Resources{Config: cfg, Checkpoints: nil, Memory: &mockMemoryStats{count: 42}, Version: "test-v1"}
	return NewHandler(res)
}

func validateDashboardResponse(t *testing.T, h *Handler, path string, expectedStatus int, expectedBody []string) {
	t.Helper()
	req := httptest.NewRequestWithContext(context.Background(), "GET", path, http.NoBody)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)
	if w.Code != expectedStatus {
		t.Errorf("status: got %d, want %d", w.Code, expectedStatus)
	}
	if expectedBody != nil {
		body := w.Body.String()
		for _, exp := range expectedBody {
			if !strings.Contains(body, exp) {
				t.Errorf("body missing %q", exp)
			}
		}
	}
}

func TestAuthMiddleware(t *testing.T) {
	t.Parallel()

	target := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("OK"))
	})

	tests := []struct {
		name           string
		token          string
		header         string
		query          string
		cookie         string
		expectedStatus int
	}{
		{"NoTokenConfigured", "", "", "", "", http.StatusOK},
		{"ValidHeader", "secret123", "Bearer secret123", "", "", http.StatusOK},
		{"InvalidHeader", "secret123", "Bearer bad", "", "", http.StatusUnauthorized},
		{"ValidQuery", "secret123", "", "secret123", "", http.StatusOK},
		{"InvalidQuery", "secret123", "", "bad", "", http.StatusUnauthorized},
		{"ValidCookie", "secret123", "", "", "secret123", http.StatusOK},
		{"InvalidCookie", "secret123", "", "", "bad", http.StatusUnauthorized},
		{"MissingAll", "secret123", "", "", "", http.StatusUnauthorized},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			path := "/dash/"
			if tt.query != "" {
				path += "?token=" + tt.query
			}
			req := httptest.NewRequestWithContext(context.Background(), "GET", path, http.NoBody)

			if tt.header != "" {
				req.Header.Set("Authorization", tt.header)
			}
			if tt.cookie != "" {
				req.AddCookie(&http.Cookie{Name: "gobot_token", Value: tt.cookie})
			}

			w := httptest.NewRecorder()
			middleware := AuthMiddleware(tt.token, target)
			middleware.ServeHTTP(w, req)

			if w.Code != tt.expectedStatus {
				t.Errorf("expected status %d, got %d", tt.expectedStatus, w.Code)
			}
		})
	}
}

func TestRenderError(t *testing.T) {
	t.Parallel()
	res := Resources{
		Config: &config.Config{},
	}
	// Create handler without templates to force error
	h := &Handler{res: res, pages: nil}

	req := httptest.NewRequestWithContext(context.Background(), "GET", "/dash/", http.NoBody)
	w := httptest.NewRecorder()

	h.ServeHTTP(w, req)

	if w.Code != http.StatusInternalServerError {
		t.Errorf("expected 500 status when templates missing, got %d", w.Code)
	}
}
