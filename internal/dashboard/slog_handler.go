package dashboard

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"time"
)

// SlogHandler is a slog.Handler that emits log entries to a Hub.
type SlogHandler struct {
	hub  *Hub
	next slog.Handler
}

// NewSlogHandler creates a new SlogHandler wrapping the provided handler.
func NewSlogHandler(hub *Hub, next slog.Handler) *SlogHandler {
	return &SlogHandler{
		hub:  hub,
		next: next,
	}
}

// Enabled implements slog.Handler.
func (h *SlogHandler) Enabled(ctx context.Context, level slog.Level) bool {
	return h.next.Enabled(ctx, level)
}

// Handle implements slog.Handler.
func (h *SlogHandler) Handle(ctx context.Context, r slog.Record) error {
	// Process the record for the hub
	fields := make(map[string]any)
	r.Attrs(func(a slog.Attr) bool {
		val := a.Value.Any()
		// Redaction logic
		if isSensitive(a.Key) {
			val = "[REDACTED]"
		}
		fields[a.Key] = val
		return true
	})

	entry := &LogEntry{
		Timestamp: r.Time,
		Level:     r.Level.String(),
		Message:   r.Message,
		Fields:    fields,
	}

	// Default timestamp if zero
	if entry.Timestamp.IsZero() {
		entry.Timestamp = time.Now()
	}

	h.hub.Emit(entry)

	// Pass to the next handler
	if err := h.next.Handle(ctx, r); err != nil {
		return fmt.Errorf("next handler: %w", err)
	}
	return nil
}

// WithAttrs implements slog.Handler.
func (h *SlogHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return &SlogHandler{
		hub:  h.hub,
		next: h.next.WithAttrs(attrs),
	}
}

// WithGroup implements slog.Handler.
func (h *SlogHandler) WithGroup(name string) slog.Handler {
	return &SlogHandler{
		hub:  h.hub,
		next: h.next.WithGroup(name),
	}
}

func isSensitive(key string) bool {
	k := strings.ToLower(key)
	sensitiveKeys := []string{"token", "password", "secret", "apikey", "api_key", "key", "auth"}
	for _, sk := range sensitiveKeys {
		if strings.Contains(k, sk) {
			return true
		}
	}
	return false
}