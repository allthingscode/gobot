//nolint:testpackage // intentionally tests internals
package dashboard

import (
	"context"
	"log/slog"
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
