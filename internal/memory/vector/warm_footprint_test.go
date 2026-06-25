//nolint:testpackage // exercises unexported Store internals (db) for the measurement
package vector

import (
	"context"
	"fmt"
	"runtime"
	"testing"

	"github.com/philippgille/chromem-go"
)

// TestWarmFootprintPerVector is the warm-footprint analogue of the C-330/C-331 cold
// instrumentation (R-015): it makes the resident cost of the in-memory vector index
// reproducible so the README/METRICS warm figure stays honest.
//
// It inserts N synthetic 768-dim vectors (the dimension gobot uses) into the real
// vector.Store, proves retention via Count()==N, and measures the live HeapAlloc
// delta after a forced GC. The marginal cost is ~3.6 KB/vector (768*4 = 3072 B
// embedding + ~16% chromem.Document/map overhead). The assertion is a wide
// regression guardrail, not an exact equality, so it is stable across runs while
// still catching an order-of-magnitude change (e.g. accidental double-retention).
//
// Not parallel: a live-heap delta must not race other tests' allocations. Skipped in
// -short. No Gemini calls.
//
//nolint:paralleltest // heap measurement must run in isolation from concurrent allocations
func TestWarmFootprintPerVector(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping warm-footprint measurement in -short")
	}

	const n = 5000

	embedFunc := func(ctx context.Context, text string) ([]float32, error) {
		return (&dummyEmbedder{}).Embed(ctx, text)
	}

	readHeapMiB := func() float64 {
		runtime.GC()
		runtime.GC()
		var m runtime.MemStats
		runtime.ReadMemStats(&m)
		return float64(m.HeapAlloc) / (1024 * 1024)
	}

	base := readHeapMiB()

	store, err := NewStore(t.TempDir() + "/vectors.db")
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	docs := make([]chromem.Document, 0, n)
	for i := 0; i < n; i++ {
		docs = append(docs, chromem.Document{
			ID:      fmt.Sprintf("doc-%d", i),
			Content: fmt.Sprintf("memory fact number %d", i),
		})
	}
	if err := store.AddDocuments(context.Background(), "memory_facts", docs, embedFunc); err != nil {
		t.Fatalf("AddDocuments(%d): %v", n, err)
	}
	// docs is dead after AddDocuments (chromem copies into the collection), so it is
	// not counted in the measurement below.

	if got := store.db.GetCollection("memory_facts", embedFunc).Count(); got != n {
		t.Fatalf("retention check: Count() = %d, want %d", got, n)
	}

	deltaMiB := readHeapMiB() - base
	runtime.KeepAlive(store)

	bytesPerVec := deltaMiB * 1024 * 1024 / float64(n)
	t.Logf("warm footprint: %d x 768-dim vectors => +%.1f MiB live heap (~%.0f bytes/vector)", n, deltaMiB, bytesPerVec)

	// Wide guardrail: 768*4 = 3072 B embedding + per-document overhead. Flag an
	// order-of-magnitude regression (e.g. lost retention -> too low, double-copy -> too high).
	if bytesPerVec < 2500 || bytesPerVec > 6000 {
		t.Errorf("per-vector live heap cost ~%.0f B is outside the expected 2500-6000 B band "+
			"(768-dim float32 embedding + chromem.Document overhead); investigate a retention or copy regression", bytesPerVec)
	}
}
