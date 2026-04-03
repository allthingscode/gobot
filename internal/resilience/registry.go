package resilience

import (
	"sync"
)

var (
	registryMu sync.RWMutex
	registry   = make(map[string]*Breaker)
)

// Register adds a breaker to the global registry for observability.
func Register(name string, b *Breaker) {
	registryMu.Lock()
	defer registryMu.Unlock()
	registry[name] = b
}

// Unregister removes a breaker from the global registry.
func Unregister(name string) {
	registryMu.Lock()
	defer registryMu.Unlock()
	delete(registry, name)
}

// Get returns a registered breaker by name.
func Get(name string) *Breaker {
	registryMu.RLock()
	defer registryMu.RUnlock()
	return registry[name]
}

// All returns all registered breakers.
func All() map[string]*Breaker {
	registryMu.RLock()
	defer registryMu.RUnlock()
	res := make(map[string]*Breaker, len(registry))
	for k, v := range registry {
		res[k] = v
	}
	return res
}

// ResetAll resets all registered breakers.
func ResetAll() {
	registryMu.RLock()
	defer registryMu.RUnlock()
	for _, b := range registry {
		b.Reset()
	}
}
