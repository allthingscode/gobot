//nolint:testpackage // exercises unexported doctor latency probe helpers
package doctor

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/observability"
)

func writeLatencyJSON(t *testing.T, root, body string) {
	t.Helper()
	ws := filepath.Join(root, "workspace")
	if err := os.MkdirAll(ws, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(ws, "latency.json"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestCheckLatency_MissingSnapshotIsOK(t *testing.T) {
	t.Parallel()
	r := checkLatency(cfgWithRoot(t.TempDir()))
	if !r.OK || r.Critical {
		t.Fatalf("missing latency snapshot = {OK:%v Critical:%v}, want advisory OK", r.OK, r.Critical)
	}
	if r.Detail != "not recorded yet" {
		t.Fatalf("Detail = %q, want missing marker detail", r.Detail)
	}
}

func TestCheckLatency_EmptySnapshotIsDistinct(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	snapshot := observability.NewLatencyRecorder(5).Snapshot()
	if err := observability.WriteLatencySnapshot(root, snapshot); err != nil {
		t.Fatalf("WriteLatencySnapshot: %v", err)
	}

	r := checkLatency(cfgWithRoot(root))
	if !r.OK {
		t.Fatalf("empty latency snapshot should be OK, got %+v", r)
	}
	if r.Detail != "recorded, no samples yet" {
		t.Fatalf("Detail = %q, want no-sample marker detail", r.Detail)
	}
}

func TestCheckLatency_MeasuredSnapshot(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	now := time.Date(2026, 7, 8, 3, 0, 0, 0, time.UTC)
	p50 := int64(123)
	p99 := int64(2400)
	snapshot := observability.LatencySnapshot{
		Version:     observability.LatencySnapshotVersion,
		GeneratedAt: now,
		Metrics: []observability.LatencyMetricSnapshot{
			{Name: observability.LatencyMetricAgentDispatch, Count: 10, P50MS: &p50, P99MS: &p99, UpdatedAt: now},
		},
	}
	if err := observability.WriteLatencySnapshot(root, snapshot); err != nil {
		t.Fatalf("WriteLatencySnapshot: %v", err)
	}

	r := checkLatency(cfgWithRoot(root))
	if !r.OK {
		t.Fatalf("measured latency snapshot should be OK, got %+v", r)
	}
	if !strings.Contains(r.Detail, "agent p50 123ms, p99 2400ms") {
		t.Fatalf("Detail = %q, want measured latency", r.Detail)
	}
}

func TestCheckLatency_InvalidSnapshotWarns(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	writeLatencyJSON(t, root, "{not json")

	r := checkLatency(cfgWithRoot(root))
	if r.OK {
		t.Fatal("invalid latency snapshot must be advisory WARN (OK=false)")
	}
	if r.Critical {
		t.Fatal("invalid latency snapshot must remain non-critical")
	}
	if r.Remediation == "" {
		t.Fatal("invalid latency snapshot must carry a remediation")
	}
}

func TestGetResults_IncludesLatency(t *testing.T) {
	t.Parallel()
	results := GetResults(doctorTestCfg(t), nil)
	for i := range results {
		if results[i].Name == "latency" {
			if results[i].Critical {
				t.Fatal("latency result must be non-critical")
			}
			return
		}
	}
	t.Fatal("GetResults did not include a 'latency' result")
}
