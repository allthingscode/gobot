package provider

import (
	"fmt"
	"sort"
	"sync"
)

// Resolver exposes provider lookup to consumers without registration access.
type Resolver interface {
	Get(name string) (Provider, error)
}

// Registry owns a thread-safe collection of providers. Do not copy it after use.
// Its zero value is ready for use.
type Registry struct {
	providers   map[string]Provider
	providersMu sync.RWMutex
}

// NewRegistry creates an independent provider registry.
func NewRegistry() *Registry { return &Registry{providers: make(map[string]Provider)} }

// Register adds a provider to the registry.
// Returns an error if a provider with the same name is already registered.
func (r *Registry) Register(p Provider) error {
	r.providersMu.Lock()
	defer r.providersMu.Unlock()
	if r.providers == nil {
		r.providers = make(map[string]Provider)
	}
	name := p.Name()
	if _, dup := r.providers[name]; dup {
		return fmt.Errorf("provider already registered: %s", name)
	}
	r.providers[name] = p
	return nil
}

// Get returns a registered provider by name.
func (r *Registry) Get(name string) (Provider, error) {
	if r == nil {
		return nil, fmt.Errorf("provider not found: %s", name)
	}
	r.providersMu.RLock()
	defer r.providersMu.RUnlock()
	p, ok := r.providers[name]
	if !ok {
		return nil, fmt.Errorf("provider not found: %s", name)
	}
	return p, nil
}

// List returns the names of all registered providers, sorted.
func (r *Registry) List() []string {
	r.providersMu.RLock()
	defer r.providersMu.RUnlock()
	names := make([]string, 0, len(r.providers))
	for name := range r.providers {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}
