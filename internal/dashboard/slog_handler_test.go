//nolint:testpackage // intentionally tests internals
package dashboard

import (
	"context"
	"log/slog"
	"testing"
	"time"
)

func TestSlogHandler(t *testing.T) {
	t.Parallel()
	h := NewHub(10)
	defer h.Close()

	sub, _ := h.Subscribe()

	base := slog.Default().Handler()
	handler := NewSlogHandler(h, base)
	logger := slog.New(handler)

	logger.Info("test message", "foo", "val1", "token", "secret-token")

	select {
	case entry := <-sub:
		if entry.Message != "test message" {
			t.Errorf("expected 'test message', got '%s'", entry.Message)
		}
		if entry.Fields["foo"] != "val1" {
			t.Errorf("expected val1, got %v", entry.Fields["foo"])
		}
		if entry.Fields["token"] != "[REDACTED]" {
			t.Errorf("expected [REDACTED], got %v", entry.Fields["token"])
		}
	default:
		t.Error("expected log entry in hub")
	}
}

func TestSlogHandler_WithAttrs(t *testing.T) {
	t.Parallel()
	h := NewHub(10)
	defer h.Close()

	sub, _ := h.Subscribe()

	handler := NewSlogHandler(h, slog.Default().Handler())
	handler = handler.WithAttrs([]slog.Attr{slog.String("attr1", "val1")}).(*SlogHandler)
	
	r := slog.Record{
		Time:    time.Now(),
		Level:   slog.LevelInfo,
		Message: "msg",
	}
	_ = handler.Handle(context.Background(), r)

	select {
	case entry := <-sub:
		if entry.Message != "msg" {
			t.Errorf("expected msg, got %s", entry.Message)
		}
	default:
		t.Error("expected log entry")
	}
}

func TestIsSensitive(t *testing.T) {
	t.Parallel()
	tests := []struct {
		key  string
		want bool
	}{
		{"foo", false},
		{"token", true},
		{"PASSWORD", true},
		{"secret", true},
		{"api_key", true},
		{"apiKey", true},
		{"Authorization", true},
		{"key1", true}, // because it contains 'key'
	}

	for _, tt := range tests {
		if got := isSensitive(tt.key); got != tt.want {
			t.Errorf("isSensitive(%s) = %v, want %v", tt.key, got, tt.want)
		}
	}
}
