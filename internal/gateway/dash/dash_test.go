//nolint:testpackage // requires unexported handler internals for testing
package dash

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/config"
)

// mockMemoryStats implements MemoryProvider.
type mockMemoryStats struct {
	count     int
	err       error
	lastLimit int
	results   []map[string]any
}

func (m *mockMemoryStats) Stats() (int, error) {
	return m.count, m.err
}

func (m *mockMemoryStats) Search(ctx context.Context, query, sessionKey string, limit int) ([]map[string]any, error) {
	m.lastLimit = limit
	return m.results, nil
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

func TestMemorySearchUsesTop10(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	memoryMock := &mockMemoryStats{
		count: 1,
		results: []map[string]any{
			{"content": "alpha", "score": 0.99, "timestamp": "2026-01-01T00:00:00Z", "namespace": "facts"},
		},
	}
	h := NewHandler(Resources{
		Config: cfg,
		Memory: memoryMock,
	})

	req := httptest.NewRequestWithContext(context.Background(), "GET", "/dash/memory/search?q=alpha&partial=true", http.NoBody)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status: got %d, want %d", w.Code, http.StatusOK)
	}
	if memoryMock.lastLimit != 10 {
		t.Fatalf("search limit: got %d, want 10", memoryMock.lastLimit)
	}
	if !strings.Contains(w.Body.String(), "0.990") {
		t.Fatalf("body missing score rendering: %s", w.Body.String())
	}
}

func TestCronUsesConfigTasks(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	cfg.Cron.Tasks = []struct {
		Name     string `json:"name"`
		Schedule string `json:"schedule"`
	}{
		{Name: "Daily Review", Schedule: "0 9 * * *"},
	}

	h := NewHandler(Resources{Config: cfg})
	req := httptest.NewRequestWithContext(context.Background(), "GET", "/dash/cron", http.NoBody)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status: got %d, want %d", w.Code, http.StatusOK)
	}
	body := w.Body.String()
	if !strings.Contains(body, "Daily Review") {
		t.Fatalf("body missing config task name: %s", body)
	}
	if !strings.Contains(body, "0 9 * * *") {
		t.Fatalf("body missing config schedule: %s", body)
	}
}

func TestLogsTailPartial(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = dir
	logDir := filepath.Join(dir, "logs")
	if err := os.MkdirAll(logDir, 0o755); err != nil {
		t.Fatalf("mkdir logs dir: %v", err)
	}
	logPath := filepath.Join(logDir, "gobot.log")
	var sb strings.Builder
	for i := 1; i <= 210; i++ {
		fmt.Fprintf(&sb, "line-%d\n", i)
	}
	if err := os.WriteFile(logPath, []byte(sb.String()), 0o600); err != nil {
		t.Fatalf("write log file: %v", err)
	}

	h := NewHandler(Resources{Config: cfg})
	req := httptest.NewRequestWithContext(context.Background(), "GET", "/dash/logs?partial=true", http.NoBody)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status: got %d, want %d", w.Code, http.StatusOK)
	}
	body := w.Body.String()
	if strings.Contains(body, "line-1\nline-2\nline-3\n") {
		t.Fatalf("expected tail truncation to drop early lines")
	}
	if !strings.Contains(body, "line-210") {
		t.Fatalf("expected latest line in tail output")
	}
}
