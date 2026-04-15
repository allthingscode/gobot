package provider

import (
	"fmt"
	"sort"
	"sync"
)

//nolint:gochecknoglobals // Global provider registry; thread-safe via sync.RWMutex
var (
	providers   = make(map[string]Provider)
	providersMu sync.RWMutex
)

// Register adds a provider to the global registry.
// Returns an error if a provider with the same name is already registered.
func Register(p Provider) error {
	providersMu.Lock()
	defer providersMu.Unlock()
	name := p.Name()
	if _, dup := providers[name]; dup {
		return fmt.Errorf("provider already registered: %s", name)
	}
	providers[name] = p
	return nil
}

// Get returns a registered provider by name.
func Get(name string) (Provider, error) {
	providersMu.RLock()
	defer providersMu.RUnlock()
	p, ok := providers[name]
	if !ok {
		return nil, fmt.Errorf("provider not found: %s", name)
	}
	return p, nil
}

// List returns the names of all registered providers, sorted.
func List() []string {
	providersMu.RLock()
	defer providersMu.RUnlock()
	names := make([]string, 0, len(providers))
	for name := range providers {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

// ResetForTest clears all registered providers. Must only be called from tests.
// Use t.Cleanup(provider.ResetForTest) to ensure cleanup on test exit.
func ResetForTest() {
	providersMu.Lock()
	defer providersMu.Unlock()
	providers = make(map[string]Provider)
}
