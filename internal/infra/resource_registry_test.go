package infra

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"
)

// mockResource is a test resource that tracks shutdown calls.
type mockResource struct {
	name       string
	shutdownFn func() error
	shutdowns  atomic.Int32
}

func (m *mockResource) Name() string { return m.name }
func (m *mockResource) Shutdown(_ context.Context) error {
	m.shutdowns.Add(1)
	if m.shutdownFn != nil {
		return m.shutdownFn()
	}
	return nil
}

func TestResourceRegistry_Register(t *testing.T) {
	t.Parallel()
	reg := NewResourceRegistry()

	res1 := &mockResource{name: "res1"}
	_ = reg.Register(res1)

	if reg.Len() != 1 {
		t.Errorf("expected 1 resource, got %d", reg.Len())
	}

	// Duplicate registration should fail
	if err := reg.Register(&mockResource{name: "res1"}); err == nil {
		t.Error("expected error for duplicate registration")
	}
}

func TestResourceRegistry_Unregister(t *testing.T) {
	t.Parallel()
	reg := NewResourceRegistry()

	res1 := &mockResource{name: "res1"}
	_ = reg.Register(res1)

	removed := reg.Unregister("res1")
	if removed == nil {
		t.Error("expected removed resource, got nil")
	}
	if removed.Name() != "res1" {
		t.Errorf("expected res1, got %s", removed.Name())
	}

	if reg.Len() != 0 {
		t.Errorf("expected 0 resources, got %d", reg.Len())
	}

	// Unregister non-existent should return nil
	if reg.Unregister("nonexistent") != nil {
		t.Error("expected nil for non-existent resource")
	}
}

func TestResourceRegistry_Get(t *testing.T) {
	t.Parallel()
	reg := NewResourceRegistry()

	res1 := &mockResource{name: "res1"}
	_ = reg.Register(res1)

	got := reg.Get("res1")
	if got == nil {
		t.Fatal("expected resource, got nil")
	}
	if got.Name() != "res1" {
		t.Errorf("expected res1, got %s", got.Name())
	}

	if reg.Get("nonexistent") != nil {
		t.Error("expected nil for non-existent resource")
	}
}

func TestResourceRegistry_Shutdown(t *testing.T) {
	t.Parallel()
	reg := NewResourceRegistry()

	res1 := &mockResource{name: "res1"}
	res2 := &mockResource{name: "res2"}

	_ = reg.Register(res1)
	_ = reg.Register(res2)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := reg.Shutdown(ctx); err != nil {
		t.Fatalf("Shutdown failed: %v", err)
	}

	if res1.shutdowns.Load() != 1 {
		t.Errorf("expected res1 shutdown once, got %d", res1.shutdowns.Load())
	}
	if res2.shutdowns.Load() != 1 {
		t.Errorf("expected res2 shutdown once, got %d", res2.shutdowns.Load())
	}

	// Registry should be empty after shutdown
	if reg.Len() != 0 {
		t.Errorf("expected 0 resources after shutdown, got %d", reg.Len())
	}
}

func TestResourceRegistry_Shutdown_Order(t *testing.T) {
	t.Parallel()
	reg := NewResourceRegistry()

	var order []string

	res1 := &mockResource{
		name: "res1",
		shutdownFn: func() error {
			order = append(order, "res1")
			return nil
		},
	}
	res2 := &mockResource{
		name: "res2",
		shutdownFn: func() error {
			order = append(order, "res2")
			return nil
		},
	}
	res3 := &mockResource{
		name: "res3",
		shutdownFn: func() error {
			order = append(order, "res3")
			return nil
		},
	}

	_ = reg.Register(res1)
	_ = reg.Register(res2)
	_ = reg.Register(res3)

	ctx := context.Background()
	_ = reg.Shutdown(ctx)

	// Should shutdown in reverse order: res3, res2, res1
	expected := []string{"res3", "res2", "res1"}
	if len(order) != len(expected) {
		t.Fatalf("expected %d shutdowns, got %d", len(expected), len(order))
	}
	for i, exp := range expected {
		if order[i] != exp {
			t.Errorf("shutdown order[%d]: expected %s, got %s", i, exp, order[i])
		}
	}
}

func TestResourceRegistry_Shutdown_Error(t *testing.T) {
	t.Parallel()
	reg := NewResourceRegistry()

	res1 := &mockResource{name: "res1"}
	res2 := &mockResource{
		name: "res2",
		shutdownFn: func() error {
			return errors.New("shutdown failed")
		},
	}

	_ = reg.Register(res1)
	_ = reg.Register(res2)

	ctx := context.Background()
	err := reg.Shutdown(ctx)

	if err == nil {
		t.Fatal("expected error from shutdown")
	}

	// Both should still be called
	if res1.shutdowns.Load() != 1 {
		t.Error("expected res1 to be shutdown despite res2 error")
	}
}

func TestResourceRegistry_Shutdown_Timeout(t *testing.T) {
	t.Parallel()
	reg := NewResourceRegistry()

	res1 := &mockResource{
		name: "res1",
		shutdownFn: func() error {
			time.Sleep(5 * time.Second)
			return nil
		},
	}

	_ = reg.Register(res1)

	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()

	err := reg.Shutdown(ctx)
	if err == nil {
		t.Error("expected timeout error")
	}
}

func TestResourceRegistry_Metrics(t *testing.T) {
	t.Parallel()
	reg := NewResourceRegistry()

	res1 := &mockResource{name: "res1"}
	_ = reg.Register(res1)
	reg.Unregister("res1")

	metrics := reg.Metrics()
	if metrics.Registered != 1 {
		t.Errorf("expected 1 registered, got %d", metrics.Registered)
	}
	if metrics.Unregistered != 1 {
		t.Errorf("expected 1 unregistered, got %d", metrics.Unregistered)
	}
}

func TestDefaultRegistry(t *testing.T) {
	t.Parallel()
	// Reset default registry for testing
	DefaultRegistry = NewResourceRegistry()

	res1 := &mockResource{name: "default-res1"}
	if err := Register(res1); err != nil {
		t.Fatalf("Register failed: %v", err)
	}

	if DefaultRegistry.Len() != 1 {
		t.Errorf("expected 1 resource in default registry, got %d", DefaultRegistry.Len())
	}

	Unregister("default-res1")
	if DefaultRegistry.Len() != 0 {
		t.Errorf("expected 0 resources after unregister, got %d", DefaultRegistry.Len())
	}
}

func TestClosableResource(t *testing.T) {
	t.Parallel()
	var closed bool
	res := NewClosableResource("closable", func() error {
		closed = true
		return nil
	})

	if res.Name() != "closable" {
		t.Errorf("expected name 'closable', got %s", res.Name())
	}

	ctx := context.Background()
	if err := res.Shutdown(ctx); err != nil {
		t.Fatalf("Shutdown failed: %v", err)
	}

	if !closed {
		t.Error("expected close function to be called")
	}

	// Second shutdown should be no-op
	if err := res.Shutdown(ctx); err != nil {
		t.Errorf("second shutdown should succeed: %v", err)
	}
}

func TestClosableResource_Close(t *testing.T) {
	t.Parallel()
	var closed bool
	res := NewClosableResource("closable", func() error {
		closed = true
		return nil
	})

	// Close uses background context with timeout
	if err := res.Close(); err != nil {
		t.Fatalf("Close failed: %v", err)
	}

	if !closed {
		t.Error("expected close function to be called")
	}
}

func TestClosableResource_Timeout(t *testing.T) {
	t.Parallel()
	res := NewClosableResource("slow", func() error {
		time.Sleep(5 * time.Second)
		return nil
	})

	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()

	if err := res.Shutdown(ctx); err == nil {
		t.Error("expected timeout error")
	}
}
