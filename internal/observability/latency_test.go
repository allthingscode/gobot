//nolint:testpackage // exercises unexported latency helpers and tracer internals
package observability

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func metricByName(t *testing.T, snapshot LatencySnapshot, name string) LatencyMetricSnapshot {
	t.Helper()
	for _, metric := range snapshot.Metrics {
		if metric.Name == name {
			return metric
		}
	}
	t.Fatalf("metric %q not found in snapshot", name)
	return LatencyMetricSnapshot{}
}

func assertPercentiles(t *testing.T, metric LatencyMetricSnapshot, count int, p50, p99 int64) {
	t.Helper()
	if metric.Count != count {
		t.Fatalf("%s Count = %d, want %d", metric.Name, metric.Count, count)
	}
	if metric.P50MS == nil || *metric.P50MS != p50 {
		t.Fatalf("%s P50MS = %v, want %d", metric.Name, metric.P50MS, p50)
	}
	if metric.P99MS == nil || *metric.P99MS != p99 {
		t.Fatalf("%s P99MS = %v, want %d", metric.Name, metric.P99MS, p99)
	}
}

func TestLatencyRecorder_EmptySnapshot(t *testing.T) {
	t.Parallel()
	snapshot := NewLatencyRecorder(3).Snapshot()
	metric := metricByName(t, snapshot, LatencyMetricAgentDispatch)
	if metric.Count != 0 {
		t.Fatalf("Count = %d, want 0", metric.Count)
	}
	if metric.P50MS != nil || metric.P99MS != nil {
		t.Fatalf("empty metric percentiles = %v/%v, want nil", metric.P50MS, metric.P99MS)
	}
}

func TestLatencyRecorder_DefaultCapacityAndNilSnapshot(t *testing.T) {
	t.Parallel()
	recorder := NewLatencyRecorder(0)
	if !recorder.Record(LatencyMetricAgentDispatch, time.Millisecond) {
		t.Fatal("Record with default capacity returned false")
	}
	if recorder.Record("unknown.metric", time.Millisecond) {
		t.Fatal("Record accepted an unknown metric")
	}

	var nilRecorder *LatencyRecorder
	snapshot := nilRecorder.Snapshot()
	if snapshot.Version != LatencySnapshotVersion {
		t.Fatalf("nil Snapshot version = %d, want %d", snapshot.Version, LatencySnapshotVersion)
	}
	if len(snapshot.Metrics) != 3 {
		t.Fatalf("nil Snapshot metrics = %d, want 3", len(snapshot.Metrics))
	}
}

func TestLatencyRecorder_Percentiles(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name    string
		samples []int64
		wantP50 int64
		wantP99 int64
	}{
		{name: "one sample", samples: []int64{42}, wantP50: 42, wantP99: 42},
		{name: "ordered samples", samples: []int64{10, 20, 30, 40}, wantP50: 20, wantP99: 40},
		{name: "unordered samples", samples: []int64{90, 10, 50, 20, 70}, wantP50: 50, wantP99: 90},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			recorder := NewLatencyRecorder(10)
			for _, sample := range tt.samples {
				recorder.recordAt(LatencyMetricAgentDispatch, time.Duration(sample)*time.Millisecond, time.Now())
			}
			assertPercentiles(t, metricByName(t, recorder.Snapshot(), LatencyMetricAgentDispatch), len(tt.samples), tt.wantP50, tt.wantP99)
		})
	}
}

func TestLatencyRecorder_EvictsOldSamples(t *testing.T) {
	t.Parallel()
	recorder := NewLatencyRecorder(3)
	for _, sample := range []int64{10, 20, 30, 40} {
		recorder.recordAt(LatencyMetricToolExecute, time.Duration(sample)*time.Millisecond, time.Now())
	}
	assertPercentiles(t, metricByName(t, recorder.Snapshot(), LatencyMetricToolExecute), 3, 30, 40)
}

func TestLatencyRecorder_ConcurrentRecord(t *testing.T) {
	t.Parallel()
	recorder := NewLatencyRecorder(200)
	var wg sync.WaitGroup
	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			recorder.recordAt(LatencyMetricTelegramDispatch, time.Duration(i+1)*time.Millisecond, time.Now())
		}(i)
	}
	wg.Wait()

	metric := metricByName(t, recorder.Snapshot(), LatencyMetricTelegramDispatch)
	if metric.Count != 100 {
		t.Fatalf("Count = %d, want 100", metric.Count)
	}
}

//nolint:paralleltest // temporarily replaces slog.Default for sink warning coverage
func TestDispatchTracer_SetLatencyRecorderAndSinkError(t *testing.T) {
	var buf bytes.Buffer
	original := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&buf, nil)))
	t.Cleanup(func() { slog.SetDefault(original) })

	recorder := NewLatencyRecorder(2)
	tracer := NewDispatchTracer(nil)
	tracer.SetLatencyRecorder(recorder, func(LatencySnapshot) error {
		return errors.New("persist failed")
	})

	if err := tracer.TraceBotDispatch(context.Background(), "s", func(context.Context) error { return nil }); err != nil {
		t.Fatalf("TraceBotDispatch: %v", err)
	}
	if metricByName(t, recorder.Snapshot(), LatencyMetricTelegramDispatch).Count != 1 {
		t.Fatal("SetLatencyRecorder did not enable sampling")
	}
	if !bytes.Contains(buf.Bytes(), []byte("failed to persist latency snapshot")) {
		t.Fatalf("expected sink warning, got %q", buf.String())
	}
}

func TestLatencySnapshotPersistence(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	recorder := NewLatencyRecorder(5)
	recorder.recordAt(LatencyMetricAgentDispatch, 123*time.Millisecond, time.Now())

	if err := WriteLatencySnapshot(root, recorder.Snapshot()); err != nil {
		t.Fatalf("WriteLatencySnapshot: %v", err)
	}
	if _, err := os.Stat(LatencySnapshotPath(root)); err != nil {
		t.Fatalf("stat latency snapshot: %v", err)
	}

	snapshot, err := ReadLatencySnapshot(root)
	if err != nil {
		t.Fatalf("ReadLatencySnapshot: %v", err)
	}
	assertPercentiles(t, metricByName(t, snapshot, LatencyMetricAgentDispatch), 1, 123, 123)
}

func TestDispatchTracer_RecordsLatencyWithoutProvider(t *testing.T) {
	t.Parallel()
	const toolOutput = "out"
	recorder := NewLatencyRecorder(10)
	var writes int32
	tracer := NewDispatchTracerWithLatency(nil, recorder, func(LatencySnapshot) error {
		atomic.AddInt32(&writes, 1)
		return nil
	})
	wantErr := errors.New("keep verbatim")

	if err := tracer.TraceBotDispatch(context.Background(), "s", func(context.Context) error { return nil }); err != nil {
		t.Fatalf("TraceBotDispatch: %v", err)
	}
	if _, err := tracer.TraceAgentDispatch(context.Background(), "s", 1, func(context.Context) (string, error) { return "ok", nil }); err != nil {
		t.Fatalf("TraceAgentDispatch: %v", err)
	}
	got, err := tracer.TraceToolExecution(context.Background(), "s", "shell", func(context.Context) (string, error) {
		return toolOutput, wantErr
	})
	if got != toolOutput || err != wantErr { //nolint:errorlint // nil-provider path must return the verbatim error
		t.Fatalf("TraceToolExecution nil-provider contract changed: got %q/%v", got, err)
	}

	snapshot := recorder.Snapshot()
	for _, name := range []string{LatencyMetricTelegramDispatch, LatencyMetricAgentDispatch, LatencyMetricToolExecute} {
		if metricByName(t, snapshot, name).Count != 1 {
			t.Fatalf("%s was not sampled once: %+v", name, snapshot.Metrics)
		}
	}
	if atomic.LoadInt32(&writes) != 3 {
		t.Fatalf("snapshot writes = %d, want 3", writes)
	}
}
