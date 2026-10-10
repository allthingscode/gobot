package dashboard

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"reflect"
	"regexp"
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

type redactingSlogHandler struct {
	next slog.Handler
}

// NewRedactingSlogHandler wraps next with the dashboard log redaction policy.
func NewRedactingSlogHandler(next slog.Handler) slog.Handler {
	return &redactingSlogHandler{next: next}
}

func (h *redactingSlogHandler) Enabled(ctx context.Context, level slog.Level) bool {
	return h.next.Enabled(ctx, level)
}

func (h *redactingSlogHandler) Handle(ctx context.Context, r slog.Record) error {
	if err := h.next.Handle(ctx, redactRecord(r)); err != nil {
		return fmt.Errorf("next handler: %w", err)
	}
	return nil
}

func (h *redactingSlogHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	if len(attrs) == 0 {
		return h
	}
	return &redactingSlogHandler{next: h.next.WithAttrs(redactAttrs(attrs))}
}

func (h *redactingSlogHandler) WithGroup(name string) slog.Handler {
	if name == "" {
		return h
	}
	return &redactingSlogHandler{next: h.next.WithGroup(name)}
}

// Enabled implements slog.Handler.
func (h *SlogHandler) Enabled(ctx context.Context, level slog.Level) bool {
	return h.next.Enabled(ctx, level)
}

// Handle implements slog.Handler.
func (h *SlogHandler) Handle(ctx context.Context, r slog.Record) error {
	redacted := redactRecord(r)
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
	redacted.Attrs(func(a slog.Attr) bool {
		appendAttr(fields, prefix, a)
		return true
	})

	entry := &LogEntry{
		Timestamp: redacted.Time,
		Level:     redacted.Level.String(),
		Message:   redacted.Message,
		Fields:    fields,
	}

	// Default timestamp if zero
	if entry.Timestamp.IsZero() {
		entry.Timestamp = time.Now()
	}

	h.hub.Emit(entry)

	// Pass to the next handler
	if err := h.next.Handle(ctx, redacted); err != nil {
		return fmt.Errorf("next handler: %w", err)
	}
	return nil
}

func redactRecord(r slog.Record) slog.Record {
	redacted := slog.NewRecord(r.Time, r.Level, redactSecrets(r.Message), r.PC)
	r.Attrs(func(a slog.Attr) bool {
		redacted.AddAttrs(redactAttr(a))
		return true
	})
	return redacted
}

func redactAttrs(attrs []slog.Attr) []slog.Attr {
	if len(attrs) == 0 {
		return nil
	}
	redacted := make([]slog.Attr, 0, len(attrs))
	for _, a := range attrs {
		ra := redactAttr(a)
		if !ra.Equal(slog.Attr{}) {
			redacted = append(redacted, ra)
		}
	}
	return redacted
}

func redactAttr(a slog.Attr) slog.Attr {
	a.Value = a.Value.Resolve()
	if a.Equal(slog.Attr{}) {
		return slog.Attr{}
	}
	if a.Value.Kind() == slog.KindGroup {
		attrs := redactAttrs(a.Value.Group())
		if len(attrs) == 0 {
			return slog.Attr{}
		}
		return slog.Group(a.Key, attrsToAny(attrs)...)
	}
	if isSensitive(a.Key) {
		a.Value = slog.StringValue(redactedToken)
		return a
	}
	if a.Value.Kind() == slog.KindString {
		a.Value = slog.StringValue(redactSecrets(a.Value.String()))
	} else if a.Value.Kind() == slog.KindAny {
		a.Value = slog.AnyValue(normalizeLogValue(a.Value.Any(), 0))
	}
	return a
}

// normalizeLogValue snapshots values into inert diagnostics. Unsafe branches,
// including cycles that reach the depth bound, fail closed instead of retaining
// an object or exposing a serialization error. Methods are consumed here once;
// downstream renderers receive only scalars and copied collections.
func normalizeLogValue(value any, depth int) any {
	if depth >= 32 {
		return redactedToken
	}
	if value == nil {
		return nil
	}
	rv := reflect.ValueOf(value)
	switch rv.Kind() {
	case reflect.Pointer, reflect.Map, reflect.Slice, reflect.Chan, reflect.Func, reflect.Interface:
		if rv.IsNil() {
			return nil
		}
	default:
	}
	return normalizeNonNilValue(value, rv, depth)
}

func normalizeNonNilValue(value any, rv reflect.Value, depth int) any {
	switch v := value.(type) {
	case json.Number:
		return normalizeNumber(v)
	case time.Time, time.Duration:
		return v
	case slog.LogValuer:
		return normalizeLogValue(slog.AnyValue(v).Resolve(), depth+1)
	case slog.Value:
		if v.Kind() == slog.KindGroup {
			return attrsAsMap(v.Group(), depth+1)
		}
		return normalizeLogValue(v.Resolve().Any(), depth+1)
	case error:
		return redactSecrets(v.Error())
	case fmt.Stringer:
		return redactSecrets(v.String())
	}
	// Custom JSON (including RawMessage) must be decoded before treating its
	// underlying map/slice/byte representation as an ordinary collection.
	if _, ok := value.(json.Marshaler); ok {
		return normalizeJSON(value, depth)
	}
	return normalizeReflectedValue(rv, depth)
}

func normalizeNumber(value json.Number) any {
	if _, err := json.Marshal(value); err != nil {
		return redactedToken
	}
	return value
}

func normalizeReflectedValue(rv reflect.Value, depth int) any {
	switch rv.Kind() {
	case reflect.String:
		return redactSecrets(rv.String())
	case reflect.Bool:
		return rv.Bool()
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		return rv.Int()
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64, reflect.Uintptr:
		return rv.Uint()
	case reflect.Float32, reflect.Float64:
		return rv.Float()
	case reflect.Map:
		return normalizeMap(rv, depth)
	case reflect.Slice, reflect.Array:
		return normalizeSequence(rv, depth)
	default:
		return normalizeJSON(rv.Interface(), depth)
	}
}

func normalizeSequence(rv reflect.Value, depth int) any {
	if rv.Type().Elem().Kind() == reflect.Uint8 {
		text := make([]byte, rv.Len())
		for i := range text {
			text[i] = byte(rv.Index(i).Uint() & 0xff)
		}
		return redactSecrets(string(text))
	}
	result := make([]any, rv.Len())
	for i := range result {
		result[i] = normalizeLogValue(rv.Index(i).Interface(), depth+1)
	}
	return result
}

func normalizeMap(rv reflect.Value, depth int) any {
	if rv.Type().Key().Kind() != reflect.String {
		return redactedToken
	}
	result := make(map[string]any, rv.Len())
	iter := rv.MapRange()
	for iter.Next() {
		key := iter.Key().String()
		if isSensitive(key) {
			result[key] = redactedToken
		} else {
			result[key] = normalizeLogValue(iter.Value().Interface(), depth+1)
		}
	}
	return result
}

func attrsAsMap(attrs []slog.Attr, depth int) map[string]any {
	fields := make(map[string]any, len(attrs))
	for _, a := range attrs {
		if isSensitive(a.Key) {
			fields[a.Key] = redactedToken
		} else {
			fields[a.Key] = normalizeLogValue(a.Value, depth)
		}
	}
	return fields
}

func normalizeJSON(value any, depth int) any {
	encoded, err := json.Marshal(value)
	if err != nil {
		return redactedToken
	}
	decoder := json.NewDecoder(bytes.NewReader(encoded))
	decoder.UseNumber()
	var decoded any
	if err := decoder.Decode(&decoded); err != nil {
		return redactedToken
	}
	return normalizeLogValue(decoded, depth+1)
}

func attrsToAny(attrs []slog.Attr) []any {
	anyAttrs := make([]any, len(attrs))
	for i, a := range attrs {
		anyAttrs[i] = a
	}
	return anyAttrs
}

// appendAttr writes a single attr into fields under prefix, recursing into
// group-valued attrs and applying redaction to sensitive leaf keys.
func appendAttr(fields map[string]any, prefix string, a slog.Attr) {
	a = redactAttr(a)
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
	switch {
	case isSensitive(a.Key):
		val = redactedToken
	case a.Value.Kind() == slog.KindString:
		// Benign key: scan the string value for embedded secret spans (C-323).
		val = redactSecrets(a.Value.String())
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
	attrs = redactAttrs(attrs)
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

const redactedToken = "[REDACTED]"

// Redaction patterns for secrets embedded in free text (the record Message or a
// string attribute value). These run on the dashboard hot path, so they are
// compiled exactly once at package scope. The set is deliberately conservative -
// only well-known secret shapes match - so commit SHAs, UUIDs, and ordinary URLs
// pass through untouched (C-323). Generic entropy/length heuristics are out of
// scope precisely because they mangle benign output.
//
//nolint:gochecknoglobals // read-only compiled patterns, consulted on every log line
var (
	// reURLAuth matches the userinfo (user:pass@) component of a URL.
	reURLAuth = regexp.MustCompile(`://[^/\s:@]+:[^/\s@]+@`)
	// reKeyVal matches a known secret name followed by =/: and its value; only
	// the value is redacted so the surrounding text stays readable.
	reKeyVal = regexp.MustCompile(`(?i)\b(token|api[_-]?key|secret|password|passwd|access[_-]?token|refresh[_-]?token|auth)(\s*[=:]\s*)([^&\s"']+)`)
	// reBearer matches an Authorization bearer credential.
	reBearer = regexp.MustCompile(`(?i)\bbearer\s+[A-Za-z0-9._~+/=\-]+`)
	// secretTokenPatterns match self-identifying secret tokens whose entire span
	// is the secret.
	secretTokenPatterns = []*regexp.Regexp{
		regexp.MustCompile(`sk-[A-Za-z0-9]{16,}`),                                     // OpenAI-style API key
		regexp.MustCompile(`gh[pousr]_[A-Za-z0-9]{20,}`),                              // GitHub PAT / OAuth token
		regexp.MustCompile(`github_pat_[A-Za-z0-9_]{20,}`),                            // GitHub fine-grained PAT
		regexp.MustCompile(`AKIA[0-9A-Z]{16}`),                                        // AWS access key ID
		regexp.MustCompile(`eyJ[A-Za-z0-9_\-]+\.eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+`), // JWT
	}
)

// redactSecrets masks high-confidence secret spans inside a free-text string
// while leaving surrounding context intact. It is conservative by design: only
// well-known secret shapes are matched, so SHAs, UUIDs, and credential-free URLs
// are returned unchanged.
func redactSecrets(s string) string {
	if s == "" {
		return s
	}
	s = reURLAuth.ReplaceAllString(s, "://"+redactedToken+"@")
	s = reKeyVal.ReplaceAllString(s, "${1}${2}"+redactedToken)
	s = reBearer.ReplaceAllString(s, "Bearer "+redactedToken)
	for _, re := range secretTokenPatterns {
		s = re.ReplaceAllString(s, redactedToken)
	}
	return s
}
