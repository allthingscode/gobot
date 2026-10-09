//nolint:testpackage // in-package test for the provider registry
package provider

import (
	"context"
	"fmt"
	"reflect"
	"sort"
	"sync"
	"testing"
)

// regFakeProvider is a minimal Provider implementation for registry tests.
type regFakeProvider struct{ name string }

func (f regFakeProvider) Name() string { return f.name }
func (f regFakeProvider) Chat(context.Context, ChatRequest) (*ChatResponse, error) {
	return nil, nil
}
func (f regFakeProvider) Models() []ModelInfo { return nil }

func TestRegistry_RegisterGetAndDuplicate(t *testing.T) {
	t.Parallel()
	registry := NewRegistry()

	if err := registry.Register(regFakeProvider{name: "alpha"}); err != nil {
		t.Fatalf("Register alpha: %v", err)
	}

	got, err := registry.Get("alpha")
	if err != nil {
		t.Fatalf("Get alpha: %v", err)
	}
	if got.Name() != "alpha" {
		t.Errorf("Get returned %q, want alpha", got.Name())
	}

	if err := registry.Register(regFakeProvider{name: "alpha"}); err == nil {
		t.Error("expected duplicate-register error, got nil")
	}
}

func TestRegistry_GetMissing(t *testing.T) {
	t.Parallel()
	registry := NewRegistry()
	var absent *Registry
	if _, err := absent.Get("nope"); err == nil {
		t.Fatal("nil registry lookup succeeded")
	}

	if _, err := registry.Get("nope"); err == nil {
		t.Error("expected not-found error for unregistered provider, got nil")
	}
}

func TestRegistry_ListSorted(t *testing.T) {
	t.Parallel()
	registry := NewRegistry()

	for _, n := range []string{"gamma", "alpha", "beta"} {
		if err := registry.Register(regFakeProvider{name: n}); err != nil {
			t.Fatalf("Register %s: %v", n, err)
		}
	}

	got := registry.List()
	want := []string{"alpha", "beta", "gamma"}
	if len(got) != len(want) {
		t.Fatalf("List length = %d, want %d (%v)", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("registry.List()[%d] = %q, want %q (full: %v)", i, got[i], want[i], got)
		}
	}
}

//nolint:gocognit,cyclop // Keep cross-owner setup and provider identity assertions together.
func TestRegistry_IndependentOwners(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name  string
		first *Registry
	}{
		{"constructed", NewRegistry()}, {"zero value", &Registry{}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			other := NewRegistry()
			a, b := &regFakeProvider{name: "shared"}, &regFakeProvider{name: "shared"}
			for _, pair := range []struct {
				registry *Registry
				prov     Provider
			}{{tc.first, a}, {other, b}} {
				if err := pair.registry.Register(pair.prov); err != nil {
					t.Fatal(err)
				}
				got, err := pair.registry.Get("shared")
				if err != nil || got != pair.prov {
					t.Fatalf("resolved %v, %v; want %v", got, err, pair.prov)
				}
				if err := pair.registry.Register(pair.prov); err == nil {
					t.Fatal("duplicate accepted")
				}
			}
			if err := tc.first.Register(&regFakeProvider{name: "only-first"}); err != nil {
				t.Fatal(err)
			}
			if _, err := other.Get("only-first"); err == nil {
				t.Fatal("other owner contaminated")
			}
			if !reflect.DeepEqual(tc.first.List(), []string{"only-first", "shared"}) || !reflect.DeepEqual(other.List(), []string{"shared"}) {
				t.Fatal("lists not independent and sorted")
			}
		})
	}
}

//nolint:gocognit // Keep cross-owner setup and provider identity assertions together.
func TestRegistry_ConcurrentOwners(t *testing.T) {
	t.Parallel()
	registries := []*Registry{NewRegistry(), NewRegistry()}
	var wg sync.WaitGroup
	for _, registry := range registries {
		for i := 0; i < 32; i++ {
			wg.Go(func() {
				name := fmt.Sprintf("provider-%02d", i)
				prov := &regFakeProvider{name: name}
				if err := registry.Register(prov); err != nil {
					t.Error(err)
					return
				}
				if got, err := registry.Get(name); err != nil || got != prov {
					t.Errorf("Get = %v, %v", got, err)
				}
				if names := registry.List(); !sort.StringsAreSorted(names) {
					t.Error("unsorted concurrent list")
				}
			})
		}
	}
	wg.Wait()
	for _, registry := range registries {
		if len(registry.List()) != 32 {
			t.Fatal("lost registrations")
		}
	}
}
