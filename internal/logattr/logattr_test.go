package logattr_test

import (
	"bytes"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/dashboard"
	"github.com/allthingscode/gobot/internal/logattr"
)

func TestErrRedactingSink(t *testing.T) {
	t.Parallel()
	err := fmt.Errorf("request failed: %w", errors.New("token=synthetic-marker"))
	attr := logattr.Err(err)
	if attr.Key != "err" || !errors.Is(attr.Value.Any().(error), err) {
		t.Fatal("Err constructor contract changed")
	}
	var output bytes.Buffer
	logger := slog.New(dashboard.NewRedactingSlogHandler(slog.NewJSONHandler(&output, nil)))
	logger.Info("diagnostic", attr)
	if strings.Contains(output.String(), "synthetic-marker") || !strings.Contains(output.String(), "request failed") {
		t.Fatal(output.String())
	}
}

func TestConstructors(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		attr     slog.Attr
		expected slog.Attr
	}{
		{
			name:     "SessionKey",
			attr:     logattr.SessionKey("test-session"),
			expected: slog.String("session_key", "test-session"),
		},
		{
			name:     "UserID",
			attr:     logattr.UserID("test-user"),
			expected: slog.String("user_id", "test-user"),
		},
		{
			name:     "ToolName",
			attr:     logattr.ToolName("test-tool"),
			expected: slog.String("tool", "test-tool"),
		},
		{
			name:     "Model",
			attr:     logattr.Model("test-model"),
			expected: slog.String("model", "test-model"),
		},
		{
			name:     "Provider",
			attr:     logattr.Provider("test-provider"),
			expected: slog.String("provider", "test-provider"),
		},
		{
			name:     "Attempt",
			attr:     logattr.Attempt(1),
			expected: slog.Int("attempt", 1),
		},
		{
			name:     "Err",
			attr:     logattr.Err(errors.New("test-error")),
			expected: slog.Any("err", errors.New("test-error")),
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			if tt.attr.Key != tt.expected.Key {
				t.Errorf("expected key %s, got %s", tt.expected.Key, tt.attr.Key)
			}
			if tt.attr.Value.String() != tt.expected.Value.String() {
				t.Errorf("expected value %v, got %v", tt.expected.Value, tt.attr.Value)
			}
		})
	}
}
