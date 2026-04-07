package audit

import (
	"context"
	"log/slog"
	"os"
	"regexp"
	"strings"
)

// redactPatterns are compiled once at init. Each pattern matches a secret prefix
// followed by the token body; the entire match is replaced with [REDACTED].
var redactPatterns = []*regexp.Regexp{
	regexp.MustCompile(`AIzaSy[A-Za-z0-9_\-]{33}`),   // Google / Gemini API key
	regexp.MustCompile(`ya29\.[A-Za-z0-9_\-.]{10,}`), // Google OAuth access token
	regexp.MustCompile(`xoxb-[A-Za-z0-9\-]+`),        // Slack bot token
}

// triggerPrefixes are used for a fast pre-check before applying regex.
var triggerPrefixes = []string{"AIzaSy", "ya29.", "xoxb-"}

// needsRedaction returns true if s contains at least one trigger prefix.
func needsRedaction(s string) bool {
	for _, p := range triggerPrefixes {
		if strings.Contains(s, p) {
			return true
		}
	}
	return false
}

// redactString replaces any secrets in s with [REDACTED].
// Fast path: if no trigger prefix is present, returns s unchanged.
func redactString(s string) string {
	if !needsRedaction(s) {
		return s
	}
	for _, p := range redactPatterns {
		s = p.ReplaceAllString(s, "[REDACTED]")
	}
	return s
}

// redactAttr recursively redacts string values inside a slog.Attr.
func redactAttr(a slog.Attr) slog.Attr {
	v := a.Value.Resolve()
	switch v.Kind() {
	case slog.KindString:
		return slog.String(a.Key, redactString(v.String()))
	case slog.KindGroup:
		attrs := v.Group()
		redacted := make([]slog.Attr, len(attrs))
		for i, ga := range attrs {
			redacted[i] = redactAttr(ga)
		}
		return slog.Attr{Key: a.Key, Value: slog.GroupValue(redacted...)}
	default:
		// For non-string kinds, check the string representation as a safety net.
		s := v.String()
		if rs := redactString(s); rs != s {
			return slog.String(a.Key, rs)
		}
		return a
	}
}

// RedactingHandler wraps an inner slog.Handler and redacts secrets from all
// log messages and attribute values before forwarding to the inner handler.
//
// Set the PII_DEBUG_MODE environment variable to disable redaction (dev only).
type RedactingHandler struct {
	inner   slog.Handler
	enabled bool
}

// NewRedactingHandler returns a RedactingHandler wrapping inner.
// Redaction is disabled when the PII_DEBUG_MODE env var is set to any value.
func NewRedactingHandler(inner slog.Handler) *RedactingHandler {
	_, debug := os.LookupEnv("PII_DEBUG_MODE")
	return &RedactingHandler{inner: inner, enabled: !debug}
}

func (h *RedactingHandler) Enabled(ctx context.Context, level slog.Level) bool {
	return h.inner.Enabled(ctx, level)
}

func (h *RedactingHandler) Handle(ctx context.Context, r slog.Record) error {
	if !h.enabled {
		return h.inner.Handle(ctx, r)
	}
	newR := slog.NewRecord(r.Time, r.Level, redactString(r.Message), r.PC)
	r.Attrs(func(a slog.Attr) bool {
		newR.AddAttrs(redactAttr(a))
		return true
	})
	return h.inner.Handle(ctx, newR)
}

func (h *RedactingHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	if !h.enabled {
		return &RedactingHandler{inner: h.inner.WithAttrs(attrs), enabled: false}
	}
	redacted := make([]slog.Attr, len(attrs))
	for i, a := range attrs {
		redacted[i] = redactAttr(a)
	}
	return &RedactingHandler{inner: h.inner.WithAttrs(redacted), enabled: true}
}

func (h *RedactingHandler) WithGroup(name string) slog.Handler {
	return &RedactingHandler{inner: h.inner.WithGroup(name), enabled: h.enabled}
}
