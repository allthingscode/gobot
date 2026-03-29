package audit

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"testing"
)

// captureHandler records every Record passed to Handle.
type captureHandler struct {
	buf   *bytes.Buffer
	attrs []slog.Attr
}

func (h *captureHandler) Enabled(_ context.Context, _ slog.Level) bool { return true }
func (h *captureHandler) Handle(_ context.Context, r slog.Record) error {
	h.buf.WriteString(r.Message)
	// Write attributes from WithAttrs first.
	for _, a := range h.attrs {
		h.buf.WriteString(" " + a.Key + "=" + a.Value.String())
	}
	// Then write attributes from the record.
	r.Attrs(func(a slog.Attr) bool {
		h.buf.WriteString(" " + a.Key + "=" + a.Value.String())
		return true
	})
	h.buf.WriteString("\n")
	return nil
}
func (h *captureHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return &captureHandler{
		buf:   h.buf,
		attrs: append(h.attrs, attrs...),
	}
}
func (h *captureHandler) WithGroup(_ string) slog.Handler { return h }

func TestRedactString(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		{"clean string", "hello world", "hello world"},
		{"empty", "", ""},
		{"gemini key", "key=AIzaSyABCDEFGHIJKLMNOPQRSTUVWXYZ0123456", "key=[REDACTED]"},
		{"oauth token", "token=ya29.abcdefghijklmnopqrstuvwxyz", "token=[REDACTED]"},
		{"slack token", "tok=xoxb-123456789-abcdefghij", "tok=[REDACTED]"},
		{"no trigger prefix", "some random log message", "some random log message"},
		{"mixed content", "key=AIzaSyABCDEFGHIJKLMNOPQRSTUVWXYZ0123456 user=alice", "key=[REDACTED] user=alice"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := redactString(tt.input)
			if got != tt.want {
				t.Errorf("redactString(%q) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

func TestRedactingHandler_RedactsMessage(t *testing.T) {
	cap := &captureHandler{buf: &bytes.Buffer{}}
	h := NewRedactingHandler(cap)
	logger := slog.New(h)
	logger.Info("secret=AIzaSyABCDEFGHIJKLMNOPQRSTUVWXYZ0123456")
	if strings.Contains(cap.buf.String(), "AIzaSy") {
		t.Errorf("log output contains unredacted key: %s", cap.buf.String())
	}
	if !strings.Contains(cap.buf.String(), "[REDACTED]") {
		t.Errorf("log output missing [REDACTED]: %s", cap.buf.String())
	}
}

func TestRedactingHandler_RedactsAttrValue(t *testing.T) {
	cap := &captureHandler{buf: &bytes.Buffer{}}
	h := NewRedactingHandler(cap)
	logger := slog.New(h)
	logger.Info("connecting", "token", "ya29.supersecrettoken123456")
	if strings.Contains(cap.buf.String(), "ya29.") {
		t.Errorf("log output contains unredacted OAuth token: %s", cap.buf.String())
	}
}

func TestRedactingHandler_PassesThroughCleanLog(t *testing.T) {
	cap := &captureHandler{buf: &bytes.Buffer{}}
	h := NewRedactingHandler(cap)
	logger := slog.New(h)
	logger.Info("user logged in", "user", "alice")
	if !strings.Contains(cap.buf.String(), "alice") {
		t.Errorf("clean value was unexpectedly stripped: %s", cap.buf.String())
	}
}

func TestRedactingHandler_PIIDebugMode(t *testing.T) {
	t.Setenv("PII_DEBUG_MODE", "1")
	cap := &captureHandler{buf: &bytes.Buffer{}}
	h := NewRedactingHandler(cap)
	logger := slog.New(h)
	logger.Info("key=AIzaSyABCDEFGHIJKLMNOPQRSTUVWXYZ0123456")
	// Redaction disabled — original value must be present.
	if !strings.Contains(cap.buf.String(), "AIzaSy") {
		t.Errorf("PII_DEBUG_MODE: expected unredacted output, got: %s", cap.buf.String())
	}
}

func TestNeedsRedaction(t *testing.T) {
	if needsRedaction("clean log line") {
		t.Error("clean string incorrectly flagged")
	}
	if !needsRedaction("has AIzaSy prefix") {
		t.Error("Gemini key not detected")
	}
}

func TestRedactingHandler_WithAttrs_RedactsSecret(t *testing.T) {
	cap := &captureHandler{buf: &bytes.Buffer{}}
	h := NewRedactingHandler(cap)
	// Secret is passed via With(), not via Info() args.
	logger := slog.New(h).With("token", "ya29.supersecrettoken123456")
	logger.Info("connecting")
	if strings.Contains(cap.buf.String(), "ya29.") {
		t.Errorf("WithAttrs: unredacted token in output: %s", cap.buf.String())
	}
	if !strings.Contains(cap.buf.String(), "[REDACTED]") {
		t.Errorf("WithAttrs: [REDACTED] marker missing from output: %s", cap.buf.String())
	}
}

func TestRedactAttr_GroupKind(t *testing.T) {
	// Build a group attr containing a secret and a clean value.
	inner := slog.Group("auth",
		slog.String("token", "ya29.supersecrettoken123456"),
		slog.String("user", "alice"),
	)
	result := redactAttr(inner)
	got := result.Value.String()
	if strings.Contains(got, "ya29.") {
		t.Errorf("KindGroup: unredacted token in group attr: %s", got)
	}
	if !strings.Contains(got, "alice") {
		t.Errorf("KindGroup: clean value was stripped from group attr: %s", got)
	}
}
