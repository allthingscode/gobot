package dash

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/config"
)

// mockMemoryStats implements MemoryStatsProvider
type mockMemoryStats struct {
	count int
	err   error
}

func (m *mockMemoryStats) Stats() (int, error) {
	return m.count, m.err
}

func TestDashboardHandlers(t *testing.T) {
	t.Parallel()

	cfg := &config.Config{}
	cfg.Gateway.DashboardEnabled = true

	res := Resources{
		Config:      cfg,
		Checkpoints: nil, // Mocking CheckpointManager is complex, nil is fine for partial test
		Memory:      &mockMemoryStats{count: 42},
		Version:     "test-v1",
	}

	h := NewHandler(res)

	tests := []struct {
		name           string
		path           string
		expectedStatus int
		expectedBody   []string
	}{
		{
			name:           "Home",
			path:           "/dash/",
			expectedStatus: http.StatusOK,
			expectedBody:   []string{"GoBot Dashboard", "test-v1", "System Overview"},
		},
		{
			name:           "Sessions",
			path:           "/dash/sessions",
			expectedStatus: http.StatusOK,
			expectedBody:   []string{"Active Sessions"},
		},
		{
			name:           "Memory",
			path:           "/dash/memory",
			expectedStatus: http.StatusOK,
			expectedBody:   []string{"Strategic Memory", "42"},
		},
		{
			name:           "Cron",
			path:           "/dash/cron",
			expectedStatus: http.StatusOK,
			expectedBody:   []string{"Cron Jobs"},
		},
		{
			name:           "Doctor",
			path:           "/dash/doctor",
			expectedStatus: http.StatusOK,
			expectedBody:   []string{"Doctor Diagnostics"},
		},
		{
			name:           "Doctor_Partial",
			path:           "/dash/doctor?partial=true",
			expectedStatus: http.StatusOK,
			expectedBody:   []string{"Last checked:"},
		},
		{
			name:           "Logs",
			path:           "/dash/logs",
			expectedStatus: http.StatusOK,
			expectedBody:   []string{"System Logs"},
		},
		{
			name:           "Redirect_Unknown",
			path:           "/dash/unknown",
			expectedStatus: http.StatusFound,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			req := httptest.NewRequest("GET", tt.path, http.NoBody)
			w := httptest.NewRecorder()

			h.ServeHTTP(w, req)

			if w.Code != tt.expectedStatus {
				t.Errorf("expected status %d, got %d", tt.expectedStatus, w.Code)
			}

			body := w.Body.String()
			for _, exp := range tt.expectedBody {
				if !strings.Contains(body, exp) {
					t.Errorf("expected body to contain %q", exp)
				}
			}
		})
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
			req := httptest.NewRequest("GET", path, http.NoBody)

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

	req := httptest.NewRequest("GET", "/dash/", http.NoBody)
	w := httptest.NewRecorder()

	h.ServeHTTP(w, req)

	if w.Code != http.StatusInternalServerError {
		t.Errorf("expected 500 status when templates missing, got %d", w.Code)
	}
}
