// Package infra provides infrastructure utilities for resource management.
package infra

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"
)

// Resource represents a managed resource that can be shut down.
type Resource interface {
	// Name returns a unique identifier for this resource.
	Name() string
	// Shutdown gracefully closes the resource with a timeout context.
	Shutdown(ctx context.Context) error
}

// ResourceRegistry tracks long-lived resources and provides graceful shutdown.
type ResourceRegistry struct {
	mu        sync.RWMutex
	resources map[string]Resource
	order     []string
	metrics   RegistryMetrics
}

// RegistryMetrics tracks resource lifecycle events.
type RegistryMetrics struct {
	Registered   int
	Unregistered int
	Shutdowns    int
	Failures     int
}

// NewResourceRegistry creates a new empty registry.
func NewResourceRegistry() *ResourceRegistry {
	return &ResourceRegistry{
		resources: make(map[string]Resource),
		order:     []string{},
	}
}

// Register adds a resource to the registry.
// Returns an error if a resource with the same name already exists.
func (r *ResourceRegistry) Register(res Resource) error {
	r.mu.Lock()
	defer r.mu.Unlock()

	name := res.Name()
	if _, exists := r.resources[name]; exists {
		return fmt.Errorf("resource %q already registered", name)
	}

	r.resources[name] = res
	r.order = append(r.order, name)
	r.metrics.Registered++
	slog.Debug("resource registered", "name", name)
	return nil
}

// Unregister removes a resource from the registry without shutting it down.
// Returns the removed resource or nil if not found.
func (r *ResourceRegistry) Unregister(name string) Resource {
	r.mu.Lock()
	defer r.mu.Unlock()

	res, exists := r.resources[name]
	if !exists {
		return nil
	}

	delete(r.resources, name)
	// Remove from order slice
	for i, n := range r.order {
		if n == name {
			r.order = append(r.order[:i], r.order[i+1:]...)
			break
		}
	}
	r.metrics.Unregistered++
	slog.Debug("resource unregistered", "name", name)
	return res
}

// Get returns a resource by name, or nil if not found.
func (r *ResourceRegistry) Get(name string) Resource {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.resources[name]
}

// Len returns the number of registered resources.
func (r *ResourceRegistry) Len() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.resources)
}

// Shutdown gracefully shuts down all registered resources.
// Resources are shut down in reverse registration order (LIFO).
// Returns an error aggregating all shutdown failures.
func (r *ResourceRegistry) Shutdown(ctx context.Context) error {
	r.mu.Lock()
	// Shutdown in reverse order (LIFO)
	toShutdown := make([]Resource, 0, len(r.order))
	for i := len(r.order) - 1; i >= 0; i-- {
		name := r.order[i]
		if res, exists := r.resources[name]; exists {
			toShutdown = append(toShutdown, res)
		}
	}
	// Clear the registry
	r.resources = make(map[string]Resource)
	r.order = []string{}
	r.mu.Unlock()

	if len(toShutdown) == 0 {
		return nil
	}

	var errs []error
	for _, res := range toShutdown {
		if err := r.shutdownOne(ctx, res); err != nil {
			errs = append(errs, fmt.Errorf("shutdown %q: %w", res.Name(), err))
		}
	}

	if len(errs) > 0 {
		return errors.Join(errs...)
	}
	return nil
}

// shutdownOne shuts down a single resource with timeout handling.
func (r *ResourceRegistry) shutdownOne(ctx context.Context, res Resource) error {
	done := make(chan error, 1)
	go func() {
		done <- res.Shutdown(ctx)
	}()

	select {
	case err := <-done:
		if err != nil {
			r.metrics.Failures++
			slog.Error("resource shutdown failed", "name", res.Name(), "err", err)
		} else {
			r.metrics.Shutdowns++
			slog.Debug("resource shutdown complete", "name", res.Name())
		}
		return err
	case <-ctx.Done():
		r.metrics.Failures++
		slog.Error("resource shutdown timed out", "name", res.Name())
		return fmt.Errorf("shutdown timeout: %w", ctx.Err())
	}
}

// Metrics returns a copy of current registry metrics.
func (r *ResourceRegistry) Metrics() RegistryMetrics {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.metrics
}

// DefaultRegistry is the global registry instance.
// Use this for process-wide resource tracking.
//nolint:gochecknoglobals // Global registry is the canonical instance for process-wide tracking
var DefaultRegistry = NewResourceRegistry()

// Register is a convenience wrapper for DefaultRegistry.Register.
func Register(res Resource) error {
	return DefaultRegistry.Register(res)
}

// Unregister is a convenience wrapper for DefaultRegistry.Unregister.
func Unregister(name string) Resource {
	return DefaultRegistry.Unregister(name)
}

// ShutdownAll is a convenience wrapper for DefaultRegistry.Shutdown.
func ShutdownAll(ctx context.Context) error {
	return DefaultRegistry.Shutdown(ctx)
}

// ClosableResource wraps a resource with a Close method for defer patterns.
type ClosableResource struct {
	name   string
	close  func() error
	closed bool
	mu     sync.Mutex
}

// NewClosableResource creates a resource that can be used with defer.
func NewClosableResource(name string, closeFn func() error) *ClosableResource {
	return &ClosableResource{
		name:  name,
		close: closeFn,
	}
}

// Name returns the resource name.
func (c *ClosableResource) Name() string {
	return c.name
}

// Shutdown calls the close function if not already closed.
func (c *ClosableResource) Shutdown(ctx context.Context) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.closed {
		return nil
	}

	// Use timeout from context
	done := make(chan error, 1)
	go func() {
		done <- c.close()
	}()

	select {
	case err := <-done:
		c.closed = true
		return err
	case <-ctx.Done():
		return fmt.Errorf("shutdown %s: %w", c.name, ctx.Err())
	}
}

// Close is an alias for Shutdown with background context (for defer compatibility).
func (c *ClosableResource) Close() error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	return c.Shutdown(ctx)
}
