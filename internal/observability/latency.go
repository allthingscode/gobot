package observability

import (
	"math"
	"sort"
	"sync"
	"time"
)

const (
	LatencyMetricAgentDispatch    = "agent.dispatch"
	LatencyMetricTelegramDispatch = "telegram.dispatch"
	LatencyMetricToolExecute      = "tool.execute"

	DefaultLatencyCapacity = 2048
	latencyMetricCount     = 3
)

// LatencyRecorder retains bounded in-process latency samples per fixed metric.
type LatencyRecorder struct {
	mu       sync.Mutex
	capacity int
	windows  map[string]*latencyWindow
}

type latencyWindow struct {
	samples   []int64
	next      int
	updatedAt time.Time
}

// LatencySnapshot is the compact persisted/readable view of recent latency.
type LatencySnapshot struct {
	Version     int                     `json:"version"`
	GeneratedAt time.Time               `json:"generated_at"`
	Metrics     []LatencyMetricSnapshot `json:"metrics"`
}

// LatencyMetricSnapshot reports count and nearest-rank quantiles for one metric.
type LatencyMetricSnapshot struct {
	Name      string    `json:"name"`
	Count     int       `json:"count"`
	P50MS     *int64    `json:"p50_ms,omitempty"`
	P99MS     *int64    `json:"p99_ms,omitempty"`
	UpdatedAt time.Time `json:"updated_at,omitempty"`
}

// NewLatencyRecorder creates a recorder with a bounded sample window per metric.
func NewLatencyRecorder(capacity int) *LatencyRecorder {
	if capacity <= 0 {
		capacity = DefaultLatencyCapacity
	}
	names := latencyMetricNames()
	windows := make(map[string]*latencyWindow, len(names))
	for _, name := range names {
		windows[name] = &latencyWindow{samples: make([]int64, 0, capacity)}
	}
	return &LatencyRecorder{capacity: capacity, windows: windows}
}

// Record adds one duration sample for a known latency metric.
func (r *LatencyRecorder) Record(metric string, duration time.Duration) bool {
	return r.recordAt(metric, duration, time.Now().UTC())
}

func (r *LatencyRecorder) recordAt(metric string, duration time.Duration, updatedAt time.Time) bool {
	if r == nil {
		return false
	}
	ms := duration.Milliseconds()
	if ms < 0 {
		ms = 0
	}

	r.mu.Lock()
	defer r.mu.Unlock()

	w, ok := r.windows[metric]
	if !ok {
		return false
	}
	if len(w.samples) < r.capacity {
		w.samples = append(w.samples, ms)
	} else {
		w.samples[w.next] = ms
		w.next = (w.next + 1) % r.capacity
	}
	w.updatedAt = updatedAt.UTC()
	return true
}

// Snapshot returns a stable copy of all fixed latency metric windows.
func (r *LatencyRecorder) Snapshot() LatencySnapshot {
	if r == nil {
		return emptyLatencySnapshot(time.Now().UTC())
	}

	r.mu.Lock()
	defer r.mu.Unlock()

	snapshot := LatencySnapshot{
		Version:     1,
		GeneratedAt: time.Now().UTC(),
		Metrics:     make([]LatencyMetricSnapshot, 0, latencyMetricCount),
	}
	for _, name := range latencyMetricNames() {
		w := r.windows[name]
		snapshot.Metrics = append(snapshot.Metrics, snapshotMetric(name, w.samples, w.updatedAt))
	}
	return snapshot
}

func emptyLatencySnapshot(generatedAt time.Time) LatencySnapshot {
	metrics := make([]LatencyMetricSnapshot, 0, latencyMetricCount)
	for _, name := range latencyMetricNames() {
		metrics = append(metrics, LatencyMetricSnapshot{Name: name})
	}
	return LatencySnapshot{Version: 1, GeneratedAt: generatedAt, Metrics: metrics}
}

func latencyMetricNames() [3]string {
	return [3]string{
		LatencyMetricAgentDispatch,
		LatencyMetricTelegramDispatch,
		LatencyMetricToolExecute,
	}
}

func snapshotMetric(name string, samples []int64, updatedAt time.Time) LatencyMetricSnapshot {
	metric := LatencyMetricSnapshot{Name: name, Count: len(samples), UpdatedAt: updatedAt}
	if len(samples) == 0 {
		return metric
	}

	sorted := append([]int64(nil), samples...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
	p50 := nearestRank(sorted, 50)
	p99 := nearestRank(sorted, 99)
	metric.P50MS = &p50
	metric.P99MS = &p99
	return metric
}

func nearestRank(sorted []int64, percentile int) int64 {
	if len(sorted) == 0 {
		return 0
	}
	rank := int(math.Ceil(float64(percentile) / 100 * float64(len(sorted))))
	if rank < 1 {
		rank = 1
	}
	if rank > len(sorted) {
		rank = len(sorted)
	}
	return sorted[rank-1]
}
