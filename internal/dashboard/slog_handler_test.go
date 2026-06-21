//nolint:testpackage // intentionally tests internals
package dashboard

import (
	"context"
	"log/slog"
	"strings"
	"testing"
	"time"
)

const (
	testVal1     = "val1"
	testRedacted = "[REDACTED]"
)

func TestSlogHandler(t *testing.T) {
	t.Parallel()
	h := NewHub(10)
	defer h.Close()

	sub, _ := h.Subscribe()

	base := slog.Default().Handler()
	handler := NewSlogHandler(h, base)
	logger := slog.New(handler)

	logger.Info("test message", "foo", testVal1, "token", "secret-token")

	select {
	case entry := <-sub:
		if entry.Message != "test message" {
			t.Errorf("expected 'test message', got '%s'", entry.Message)
		}
		if entry.Fields["foo"] != testVal1 {
			t.Errorf("expected val1, got %v", entry.Fields["foo"])
		}
		if entry.Fields["token"] != testRedacted {
			t.Errorf("expected [REDACTED], got %v", entry.Fields["token"])
		}
	default:
		t.Error("expected log entry in hub")
	}
}

// TestSlogHandler_RedactionPrecision exercises the value path (AC5): a benign key
// that the old substring match wrongly redacted now passes through, while a genuinely
// sensitive key still redacts.
func TestSlogHandler_RedactionPrecision(t *testing.T) {
	t.Parallel()
	h := NewHub(10)
	defer h.Close()

	sub, _ := h.Subscribe()
	handler := NewSlogHandler(h, slog.Default().Handler())
	logger := slog.New(handler)

	logger.Info("msg", "monkey", testVal1, "api_key", "sk-deadbeef")

	select {
	case entry := <-sub:
		if entry.Fields["monkey"] != testVal1 {
			t.Errorf("benign 'monkey' should pass through, got %v", entry.Fields["monkey"])
		}
		if entry.Fields["api_key"] != testRedacted {
			t.Errorf("'api_key' should be redacted, got %v", entry.Fields["api_key"])
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
	handler = handler.WithAttrs([]slog.Attr{slog.String("attr1", testVal1)}).(*SlogHandler)

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
		if entry.Fields["attr1"] != testVal1 {
			t.Errorf("expected WithAttrs attr1=val1 in fields, got %v", entry.Fields["attr1"])
		}
	default:
		t.Error("expected log entry")
	}
}

// emit logs through handler and returns the resulting hub entry, or fails.
func emit(t *testing.T, handler slog.Handler, sub <-chan *LogEntry, r slog.Record) *LogEntry {
	t.Helper()
	if err := handler.Handle(context.Background(), r); err != nil {
		t.Fatalf("Handle: %v", err)
	}
	select {
	case entry := <-sub:
		return entry
	default:
		t.Fatal("expected log entry in hub")
		return nil
	}
}

func record(msg string, attrs ...slog.Attr) slog.Record {
	r := slog.Record{Time: time.Now(), Level: slog.LevelInfo, Message: msg}
	r.AddAttrs(attrs...)
	return r
}

func TestSlogHandler_WithAttrs_ViaLogger(t *testing.T) {
	t.Parallel()
	h := NewHub(10)
	defer h.Close()
	sub, _ := h.Subscribe()

	logger := slog.New(NewSlogHandler(h, slog.Default().Handler())).With("attr1", testVal1)
	logger.Info("hello")

	select {
	case entry := <-sub:
		if entry.Fields["attr1"] != testVal1 {
			t.Errorf("expected attr1=val1, got %v", entry.Fields["attr1"])
		}
	default:
		t.Error("expected log entry")
	}
}

func TestSlogHandler_WithGroup_Prefix(t *testing.T) {
	t.Parallel()
	h := NewHub(10)
	defer h.Close()
	sub, _ := h.Subscribe()

	handler := NewSlogHandler(h, slog.Default().Handler()).
		WithGroup("g").
		WithAttrs([]slog.Attr{slog.String("k", "v")})

	entry := emit(t, handler, sub, record("msg", slog.String("inline", "iv")))
	if entry.Fields["g.k"] != "v" {
		t.Errorf("expected g.k=v, got %v", entry.Fields["g.k"])
	}
	if entry.Fields["g.inline"] != "iv" {
		t.Errorf("expected record attr namespaced as g.inline=iv, got %v", entry.Fields["g.inline"])
	}
}

func TestSlogHandler_WithGroup_EmptyNameIgnored(t *testing.T) {
	t.Parallel()
	h := NewHub(10)
	defer h.Close()
	sub, _ := h.Subscribe()

	handler := NewSlogHandler(h, slog.Default().Handler()).
		WithGroup("").
		WithAttrs([]slog.Attr{slog.String("k", "v")})

	entry := emit(t, handler, sub, record("msg"))
	if entry.Fields["k"] != "v" {
		t.Errorf("empty group must not add a prefix; expected k=v, got fields=%v", entry.Fields)
	}
}

func TestSlogHandler_RedactsAccumulatedAttrs(t *testing.T) {
	t.Parallel()
	h := NewHub(10)
	defer h.Close()
	sub, _ := h.Subscribe()

	logger := slog.New(NewSlogHandler(h, slog.Default().Handler())).With("token", "shhh")
	logger.Info("msg")

	select {
	case entry := <-sub:
		if entry.Fields["token"] != testRedacted {
			t.Errorf("expected accumulated token redacted, got %v", entry.Fields["token"])
		}
	default:
		t.Error("expected log entry")
	}
}

func TestSlogHandler_RecordAttrPrecedence(t *testing.T) {
	t.Parallel()
	h := NewHub(10)
	defer h.Close()
	sub, _ := h.Subscribe()

	handler := NewSlogHandler(h, slog.Default().Handler()).
		WithAttrs([]slog.Attr{slog.String("k", "accumulated")})

	entry := emit(t, handler, sub, record("msg", slog.String("k", "inline")))
	if entry.Fields["k"] != "inline" {
		t.Errorf("expected record-inline attr to win, got %v", entry.Fields["k"])
	}
}

func TestSlogHandler_ChainedWith(t *testing.T) {
	t.Parallel()
	h := NewHub(10)
	defer h.Close()
	sub, _ := h.Subscribe()

	handler := NewSlogHandler(h, slog.Default().Handler()).
		WithAttrs([]slog.Attr{slog.String("a", "1")}).
		WithGroup("g").
		WithAttrs([]slog.Attr{slog.String("b", "2")})

	entry := emit(t, handler, sub, record("msg", slog.String("c", "3")))
	if entry.Fields["a"] != "1" {
		t.Errorf("expected a=1 (pre-group), got %v", entry.Fields["a"])
	}
	if entry.Fields["g.b"] != "2" {
		t.Errorf("expected g.b=2, got %v", entry.Fields["g.b"])
	}
	if entry.Fields["g.c"] != "3" {
		t.Errorf("expected g.c=3 (record attr under group), got %v", entry.Fields["g.c"])
	}
}

func TestSlogHandler_SiblingsNoAlias(t *testing.T) {
	t.Parallel()
	h := NewHub(10)
	defer h.Close()
	sub, _ := h.Subscribe()

	base := NewSlogHandler(h, slog.Default().Handler()).
		WithAttrs([]slog.Attr{slog.String("base", "b")})
	left := base.WithAttrs([]slog.Attr{slog.String("side", "left")})
	right := base.WithAttrs([]slog.Attr{slog.String("side", "right")})

	le := emit(t, left, sub, record("l"))
	re := emit(t, right, sub, record("r"))
	if le.Fields["side"] != "left" {
		t.Errorf("left sibling polluted: got %v", le.Fields["side"])
	}
	if re.Fields["side"] != "right" {
		t.Errorf("right sibling polluted: got %v", re.Fields["side"])
	}
}

func TestIsSensitive(t *testing.T) {
	t.Parallel()
	tests := []struct {
		key  string
		want bool
	}{
		// True positives - genuinely sensitive field names (AC3).
		{"token", true},
		{"password", true},
		{"PASSWORD", true}, // case-insensitive
		{"secret", true},
		{"api_key", true},   // delimiter split -> token "key"
		{"apiKey", true},    // camelCase split -> token "key"
		{"apikey", true},    // single token in the set
		{"Authorization", true},
		{"auth", true},
		{"key", true},
		{"X-Auth-Token", true}, // tokens [x, auth, token]

		// False positives that the old substring match wrongly redacted (AC2).
		{"foo", false},
		{"monkey", false},
		{"donkey", false},
		{"keyboard", false},
		{"keyboard_layout", false},
		{"key1", false},           // whole-token match: "key1" != "key" (was true under substring)
		{"author", false},         // "author" != "auth"
		{"oauth_flow_step", false}, // token "oauth" != "auth"
	}

	for _, tt := range tests {
		if got := isSensitive(tt.key); got != tt.want {
			t.Errorf("isSensitive(%q) = %v, want %v", tt.key, got, tt.want)
		}
	}
}

// TestRedactSecrets exercises every Pattern-Set entry in both directions (AC3):
// each secret shape is masked, and benign look-alikes are returned verbatim.
func TestRedactSecrets(t *testing.T) {
	t.Parallel()
	const secret = "deadbeefdeadbeef1234"

	redacted := []struct {
		name string
		in   string
		leak string // substring that must NOT survive
	}{
		{"bearer", "Authorization: Bearer sk-abcdefghij1234567890", "sk-abcdefghij1234567890"},
		{"url basic-auth", "dialing https://admin:hunter2@db.example/path", "hunter2"},
		{"token query param", "GET /x?token=" + secret, secret},
		{"api_key assignment", "api_key=sk-abcdefghij1234567890 loaded", "sk-abcdefghij1234567890"},
		{"openai key", "using sk-abcdefghij1234567890 now", "sk-abcdefghij1234567890"},
		{"github pat", "token ghp_0123456789abcdefghij0123", "ghp_0123456789abcdefghij0123"},
		{"aws key id", "creds AKIAIOSFODNN7EXAMPLE here", "AKIAIOSFODNN7EXAMPLE"},
		{"jwt", "jwt eyJhbGciOiJI.eyJzdWIiOiIx.SflKxwRJSMeKK", "eyJhbGciOiJI"},
	}
	for _, tt := range redacted {
		t.Run("redacts/"+tt.name, func(t *testing.T) {
			t.Parallel()
			got := redactSecrets(tt.in)
			if strings.Contains(got, tt.leak) {
				t.Errorf("redactSecrets(%q) = %q, secret %q leaked", tt.in, got, tt.leak)
			}
			if !strings.Contains(got, testRedacted) {
				t.Errorf("redactSecrets(%q) = %q, expected a %s span", tt.in, got, testRedacted)
			}
		})
	}

	// Benign look-alikes must pass through byte-for-byte (no false positives).
	unchanged := []struct {
		name string
		in   string
	}{
		{"git sha", "merged a339d426e4bf9f271c08a8fa8b71404ad2242f8a"},
		{"uuid", "id 550e8400-e29b-41d4-a716-446655440000"},
		{"base64 data uri", "img data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAUA"},
		{"word monkey", "the monkey ate the key"},
		{"bare key=value", "key=value123 cached"},
		{"credential-free url", "GET https://example.com/path?ref=main"},
		{"empty", ""},
	}
	for _, tt := range unchanged {
		t.Run("preserves/"+tt.name, func(t *testing.T) {
			t.Parallel()
			if got := redactSecrets(tt.in); got != tt.in {
				t.Errorf("redactSecrets(%q) = %q, want unchanged", tt.in, got)
			}
		})
	}
}

// TestSlogHandler_MessageBodyRedaction covers AC1: a secret embedded in the
// record Message is masked while the surrounding text is preserved.
func TestSlogHandler_MessageBodyRedaction(t *testing.T) {
	t.Parallel()
	h := NewHub(10)
	defer h.Close()
	sub, _ := h.Subscribe()
	handler := NewSlogHandler(h, slog.Default().Handler())

	entry := emit(t, handler, sub, record("calling API with bearer sk-abcdefghij1234567890 now"))
	if strings.Contains(entry.Message, "sk-abcdefghij1234567890") {
		t.Errorf("message leaked secret: %q", entry.Message)
	}
	if !strings.Contains(entry.Message, testRedacted) {
		t.Errorf("message not redacted: %q", entry.Message)
	}
	if !strings.Contains(entry.Message, "calling API with") {
		t.Errorf("surrounding message text not preserved: %q", entry.Message)
	}
}

// TestSlogHandler_ValueRedaction_NestedGroup covers AC2: a secret in a string
// value under a benign key is masked, including when nested inside a group.
func TestSlogHandler_ValueRedaction_NestedGroup(t *testing.T) {
	t.Parallel()
	h := NewHub(10)
	defer h.Close()
	sub, _ := h.Subscribe()
	handler := NewSlogHandler(h, slog.Default().Handler()).WithGroup("net")

	entry := emit(t, handler, sub, record("fetch",
		slog.String("url", "https://api/x?token=deadbeefdeadbeef1234")))

	got, _ := entry.Fields["net.url"].(string)
	if strings.Contains(got, "deadbeefdeadbeef1234") {
		t.Errorf("nested value leaked secret: %q", got)
	}
	if !strings.Contains(got, testRedacted) {
		t.Errorf("nested value not redacted: %q", got)
	}
}

// TestSlogHandler_ValueRedaction_InlineGroup covers AC2 via appendAttr's group
// recursion: a secret in a string value inside a slog.Group is masked, and the
// group is flattened into a dotted key.
func TestSlogHandler_ValueRedaction_InlineGroup(t *testing.T) {
	t.Parallel()
	h := NewHub(10)
	defer h.Close()
	sub, _ := h.Subscribe()
	handler := NewSlogHandler(h, slog.Default().Handler())

	entry := emit(t, handler, sub, record("req",
		slog.Group("http",
			slog.String("endpoint", "https://api/x?token=deadbeefdeadbeef1234"),
			slog.String("method", "GET"),
		)))

	got, _ := entry.Fields["http.endpoint"].(string)
	if strings.Contains(got, "deadbeefdeadbeef1234") {
		t.Errorf("grouped value leaked secret: %q", got)
	}
	if !strings.Contains(got, testRedacted) {
		t.Errorf("grouped value not redacted: %q", got)
	}
	if entry.Fields["http.method"] != "GET" {
		t.Errorf("benign grouped value altered: %v", entry.Fields["http.method"])
	}
}
