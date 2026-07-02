//nolint:testpackage // covers package-private helpers
package context

import (
	"errors"
	"strings"
	"testing"
)

func TestIdempotencyHashMismatchHelper(t *testing.T) {
	t.Parallel()

	if IsIdempotencyHashMismatch(nil) {
		t.Fatal("nil error should not be mismatch")
	}
	if IsIdempotencyHashMismatch(errors.New("other error")) {
		t.Fatal("unrelated error should not be mismatch")
	}
	if !IsIdempotencyHashMismatch(errors.New("idempotency key k reused with different parameters")) {
		t.Fatal("mismatch error should be detected")
	}
}

//nolint:cyclop // Exercises several pairing and manager branches against one SQLite fixture.
func TestPairingStoreCountAuthorizedAndManagerAccessors(t *testing.T) {
	t.Parallel()

	mgr := newTestManager(t)
	if mgr.DB() == nil {
		t.Fatal("DB accessor returned nil")
	}
	store, err := NewPairingStore(mgr.DB())
	if err != nil {
		t.Fatalf("NewPairingStore: %v", err)
	}
	count, err := store.CountAuthorized()
	if err != nil {
		t.Fatalf("CountAuthorized empty: %v", err)
	}
	if count != 0 {
		t.Fatalf("empty authorized count = %d", count)
	}
	if err := store.AuthorizeByChatID(123, "operator"); err != nil {
		t.Fatalf("AuthorizeByChatID: %v", err)
	}
	count, err = store.CountAuthorized()
	if err != nil {
		t.Fatalf("CountAuthorized: %v", err)
	}
	if count != 1 {
		t.Fatalf("authorized count = %d", count)
	}

	code, err := store.GetOrCreateCode(456)
	if err != nil {
		t.Fatalf("GetOrCreateCode: %v", err)
	}
	if len(code) != 6 {
		t.Fatalf("pairing code = %q", code)
	}
	chatID, err := store.AuthorizeByCode(code)
	if err != nil {
		t.Fatalf("AuthorizeByCode: %v", err)
	}
	if chatID != 456 {
		t.Fatalf("authorized chat id = %d", chatID)
	}
	if _, err := store.AuthorizeByCode(code); err == nil || !strings.Contains(err.Error(), "not found or expired") {
		t.Fatalf("expected reused code failure, got %v", err)
	}
}

func TestMessageContentStringItems(t *testing.T) {
	t.Parallel()

	if got := (*MessageContent)(nil).String(); got != "" {
		t.Fatalf("nil String() = %q", got)
	}

	text := "hello world"
	mc := &MessageContent{Items: []ContentItem{{Text: &TextContent{Type: "text", Text: text}}}}
	if got := mc.String(); got != text {
		t.Fatalf("items String() = %q, want %q", got, text)
	}

	mcMixed := &MessageContent{Items: []ContentItem{{Thinking: &ThinkingContent{Text: "ignored"}}, {Text: &TextContent{Text: "kept"}}}}
	if got := mcMixed.String(); got != "kept" {
		t.Fatalf("mixed items String() = %q", got)
	}
}
