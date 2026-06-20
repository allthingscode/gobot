//nolint:testpackage // in-package test for the unexported global provider registry
package provider

import (
	"context"
	"testing"
)

// regFakeProvider is a minimal Provider implementation for registry tests.
type regFakeProvider struct{ name string }

func (f regFakeProvider) Name() string { return f.name }
func (f regFakeProvider) Chat(context.Context, ChatRequest) (*ChatResponse, error) {
	return nil, nil
}
func (f regFakeProvider) Models() []ModelInfo { return nil }

//nolint:paralleltest // mutates the process-global provider registry; must run serially
func TestRegistry_RegisterGetAndDuplicate(t *testing.T) {
	t.Cleanup(ResetForTest)
	ResetForTest()

	if err := Register(regFakeProvider{name: "alpha"}); err != nil {
		t.Fatalf("Register alpha: %v", err)
	}

	got, err := Get("alpha")
	if err != nil {
		t.Fatalf("Get alpha: %v", err)
	}
	if got.Name() != "alpha" {
		t.Errorf("Get returned %q, want alpha", got.Name())
	}

	if err := Register(regFakeProvider{name: "alpha"}); err == nil {
		t.Error("expected duplicate-register error, got nil")
	}
}

//nolint:paralleltest // mutates the process-global provider registry; must run serially
func TestRegistry_GetMissing(t *testing.T) {
	t.Cleanup(ResetForTest)
	ResetForTest()

	if _, err := Get("nope"); err == nil {
		t.Error("expected not-found error for unregistered provider, got nil")
	}
}

//nolint:paralleltest // mutates the process-global provider registry; must run serially
func TestRegistry_ListSorted(t *testing.T) {
	t.Cleanup(ResetForTest)
	ResetForTest()

	for _, n := range []string{"gamma", "alpha", "beta"} {
		if err := Register(regFakeProvider{name: n}); err != nil {
			t.Fatalf("Register %s: %v", n, err)
		}
	}

	got := List()
	want := []string{"alpha", "beta", "gamma"}
	if len(got) != len(want) {
		t.Fatalf("List length = %d, want %d (%v)", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("List()[%d] = %q, want %q (full: %v)", i, got[i], want[i], got)
		}
	}
}

//nolint:paralleltest // mutates the process-global provider registry; must run serially
func TestRegistry_ResetForTest(t *testing.T) {
	t.Cleanup(ResetForTest)
	ResetForTest()

	if err := Register(regFakeProvider{name: "x"}); err != nil {
		t.Fatalf("Register x: %v", err)
	}
	if len(List()) != 1 {
		t.Fatalf("precondition: expected 1 registered, got %d", len(List()))
	}

	ResetForTest()
	if n := len(List()); n != 0 {
		t.Errorf("after ResetForTest, List length = %d, want 0", n)
	}
}
