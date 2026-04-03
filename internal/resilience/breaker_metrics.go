package resilience

import (
	"sync"
	"sync/atomic"
)

// BreakerStats holds counters for circuit breaker events.
type BreakerStats struct {
	Successes uint64
	Failures  uint64
	Rejections uint64 // rejected due to open circuit
}

var globalStats = make(map[string]*BreakerStats)
var statsMu sync.RWMutex

func getStats(name string) *BreakerStats {
	statsMu.RLock()
	s, ok := globalStats[name]
	statsMu.RUnlock()
	if ok {
		return s
	}

	statsMu.Lock()
	defer statsMu.Unlock()
	s = &BreakerStats{}
	globalStats[name] = s
	return s
}

// RecordSuccess increments the success counter for a breaker.
func RecordSuccess(name string) {
	atomic.AddUint64(&getStats(name).Successes, 1)
}

// RecordFailure increments the failure counter for a breaker.
func RecordFailure(name string) {
	atomic.AddUint64(&getStats(name).Failures, 1)
}

// RecordRejection increments the rejection counter for a breaker.
func RecordRejection(name string) {
	atomic.AddUint64(&getStats(name).Rejections, 1)
}

// GetStats returns a copy of the current stats for a breaker.
func GetStats(name string) BreakerStats {
	s := getStats(name)
	return BreakerStats{
		Successes:  atomic.LoadUint64(&s.Successes),
		Failures:   atomic.LoadUint64(&s.Failures),
		Rejections: atomic.LoadUint64(&s.Rejections),
	}
}
