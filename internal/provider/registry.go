package provider

import (
	"fmt"
	"sort"
	"sync"
)

var (
	providers   = make(map[string]Provider)
	providersMu sync.RWMutex
)

// Register adds a provider to the global registry.
// Panics if a provider with the same name is already registered.
func Register(p Provider) {
	providersMu.Lock()
	defer providersMu.Unlock()
	name := p.Name()
	if _, dup := providers[name]; dup {
		panic(fmt.Sprintf("provider already registered: %s", name))
	}
	providers[name] = p
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
