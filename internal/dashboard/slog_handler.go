package dashboard

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"time"
	"unicode"
)

// groupOrAttrs records one WithGroup or WithAttrs step so Handle can replay
// them in order, preserving group nesting and attr precedence. Exactly one of
// group / attrs is set per element.
type groupOrAttrs struct {
	group string
	attrs []slog.Attr
}

// SlogHandler is a slog.Handler that emits log entries to a Hub.
type SlogHandler struct {
	hub  *Hub
	next slog.Handler
	goas []groupOrAttrs
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
	fields := make(map[string]any)

	// Replay accumulated With* state first, then overlay the record's inline
	// attrs. Inline attrs are applied last so a same-named key wins, matching
	// slog's "later wins" ordering (AC4). Groups are flattened into the key as
	// a dotted prefix to keep LogEntry.Fields a flat map (no SSE schema change).
	prefix := ""
	for _, goa := range h.goas {
		if goa.group != "" {
			prefix += goa.group + "."
			continue
		}
		for _, a := range goa.attrs {
			appendAttr(fields, prefix, a)
		}
	}
	r.Attrs(func(a slog.Attr) bool {
		appendAttr(fields, prefix, a)
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

// appendAttr writes a single attr into fields under prefix, recursing into
// group-valued attrs and applying redaction to sensitive leaf keys.
func appendAttr(fields map[string]any, prefix string, a slog.Attr) {
	a.Value = a.Value.Resolve()
	if a.Equal(slog.Attr{}) {
		return
	}
	if a.Value.Kind() == slog.KindGroup {
		attrs := a.Value.Group()
		if len(attrs) == 0 {
			return
		}
		p := prefix
		if a.Key != "" {
			p += a.Key + "."
		}
		for _, ga := range attrs {
			appendAttr(fields, p, ga)
		}
		return
	}
	val := a.Value.Any()
	if isSensitive(a.Key) {
		val = "[REDACTED]"
	}
	fields[prefix+a.Key] = val
}

// withGroupOrAttrs returns a new goas slice with goa appended, copying the
// parent's backing array so sibling handlers never share state (AC5).
func (h *SlogHandler) withGroupOrAttrs(goa groupOrAttrs) []groupOrAttrs {
	goas := make([]groupOrAttrs, len(h.goas)+1)
	copy(goas, h.goas)
	goas[len(goas)-1] = goa
	return goas
}

// WithAttrs implements slog.Handler.
func (h *SlogHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	if len(attrs) == 0 {
		return h
	}
	return &SlogHandler{
		hub:  h.hub,
		next: h.next.WithAttrs(attrs),
		goas: h.withGroupOrAttrs(groupOrAttrs{attrs: attrs}),
	}
}

// WithGroup implements slog.Handler.
func (h *SlogHandler) WithGroup(name string) slog.Handler {
	if name == "" {
		return h
	}
	return &SlogHandler{
		hub:  h.hub,
		next: h.next.WithGroup(name),
		goas: h.withGroupOrAttrs(groupOrAttrs{group: name}),
	}
}

// sensitiveTerms are the exact, lowercase field-name tokens whose values must be
// redacted. Matching is whole-token (see splitKeyTokens), NOT substring, so benign
// keys like "monkey", "keyboard_layout", "key1", or "author" are left untouched while
// "api_key", "apiKey", and "Authorization" still redact. To harden redaction, add a
// term here rather than widening to a substring match.
//
//nolint:gochecknoglobals // read-only redaction lookup table, consulted on every log line
var sensitiveTerms = map[string]struct{}{
	"token":         {},
	"password":      {},
	"passwd":        {},
	"pwd":           {},
	"secret":        {},
	"apikey":        {},
	"key":           {},
	"auth":          {},
	"authorization": {},
	"credential":    {},
	"credentials":   {},
	"bearer":        {},
}

// splitKeyTokens lower-cases key and splits it into tokens on non-alphanumeric
// delimiters (_, -, ., /, space, ...) and on camelCase boundaries (a lowercase
// letter followed by an uppercase one). Digit boundaries are deliberately NOT
// split, so "key1" stays a single token and does not match "key".
func splitKeyTokens(key string) []string {
	var tokens []string
	var b strings.Builder
	runes := []rune(key)
	flush := func() {
		if b.Len() > 0 {
			tokens = append(tokens, strings.ToLower(b.String()))
			b.Reset()
		}
	}
	for i, r := range runes {
		switch {
		case !unicode.IsLetter(r) && !unicode.IsDigit(r):
			flush() // delimiter: drop it, end the current token
		case unicode.IsUpper(r) && i > 0 && unicode.IsLower(runes[i-1]):
			flush() // camelCase boundary: lower -> Upper
			b.WriteRune(r)
		default:
			b.WriteRune(r)
		}
	}
	flush()
	return tokens
}

// isSensitive reports whether a field key names a secret, by whole-token match
// against sensitiveTerms (case-insensitive).
func isSensitive(key string) bool {
	for _, tok := range splitKeyTokens(key) {
		if _, ok := sensitiveTerms[tok]; ok {
			return true
		}
	}
	return false
}
