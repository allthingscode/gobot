package google

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestStoredToken_Expired(t *testing.T) {
	t.Parallel()

	tok := &storedToken{}
	if tok.expired() {
		t.Error("expected zero expiry to be not expired")
	}

	tok.Expiry = time.Now().Add(1 * time.Hour)
	if tok.expired() {
		t.Error("expected future expiry to be not expired")
	}

	tok.Expiry = time.Now().Add(-1 * time.Hour)
	if !tok.expired() {
		t.Error("expected past expiry to be expired")
	}

	tok.Expiry = time.Now().Add(10 * time.Second)
	if !tok.expired() {
		t.Error("expected near expiry (10s) to be expired due to 30s buffer")
	}
}

func TestRefreshToken_DetailedErrors(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name       string
		respStatus int
		respBody   any
		wantErr    string
	}{
		{
			name:       "invalid_json",
			respStatus: http.StatusOK,
			respBody:   "not-json",
			wantErr:    "invalid token refresh response",
		},
		{
			name:       "google_error_field",
			respStatus: http.StatusOK,
			respBody:   map[string]string{"error": "invalid_grant"},
			wantErr:    "invalid_grant",
		},
		{
			name:       "http_error",
			respStatus: http.StatusBadRequest,
			respBody:   map[string]string{"error": "bad_request"},
			wantErr:    "bad_request",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(tt.respStatus)
				if s, ok := tt.respBody.(string); ok {
					_, _ = w.Write([]byte(s))
				} else {
					_ = json.NewEncoder(w).Encode(tt.respBody)
				}
			}))
			defer srv.Close()

			tok := &storedToken{
				RefreshToken: "refresh",
				TokenURI:     srv.URL,
			}
			err := refreshToken(context.Background(), tok, srv.Client())
			if err == nil || (tt.wantErr != "" && !strings.Contains(err.Error(), tt.wantErr)) {
				t.Errorf("expected error containing %q, got %v", tt.wantErr, err)
			}
		})
	}
}

func TestAPIGet_401Error(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":{"message":"Invalid Credentials"}}`))
	}))
	defer srv.Close()

	err := apiGet(context.Background(), "tok", srv.URL, srv.Client(), &struct{}{})
	if err == nil || !strings.Contains(err.Error(), "gobot reauth-google") {
		t.Errorf("expected reauth hint in error, got %v", err)
	}
}

// ── buildAuthURL ──────────────────────────────────────────────────────────────

func TestBuildAuthURL(t *testing.T) {
	t.Parallel()
	result := buildAuthURL("client-id-123", "http://localhost:8080/callback", []string{"scope1", "scope2"})
	if !strings.Contains(result, "client-id-123") {
		t.Errorf("expected client-id in URL, got %q", result)
	}
	if !strings.Contains(result, "scope1") {
		t.Errorf("expected scope1 in URL, got %q", result)
	}
	if !strings.Contains(result, "accounts.google.com") {
		t.Errorf("expected google auth domain in URL, got %q", result)
	}
}

// ── doGoogleRequest error status ──────────────────────────────────────────────

func TestDoGoogleRequest_ErrorStatus(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte("bad request body"))
	}))
	defer srv.Close()

	err := doGoogleRequest(context.Background(), http.MethodPost, "tok", srv.URL, map[string]string{"key": "val"}, srv.Client(), &struct{}{})
	if err == nil || !strings.Contains(err.Error(), "400") {
		t.Errorf("expected 400 error, got %v", err)
	}
}
