package observability

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/allthingscode/gobot/internal/state"
)

const LatencySnapshotVersion = 1

// WriteLatencySnapshot persists the compact latency snapshot under workspace.
func WriteLatencySnapshot(storageRoot string, snapshot LatencySnapshot) error {
	return writeLatencySnapshot(storageRoot, snapshot, state.WriteFileJSON)
}

func writeLatencySnapshot(storageRoot string, snapshot LatencySnapshot, writeJSON func(string, any, os.FileMode) error) error {
	path := LatencySnapshotPath(storageRoot)
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("create latency snapshot directory: %w", err)
	}
	if err := writeJSON(path, snapshot, 0o600); err != nil {
		return fmt.Errorf("write latency snapshot: %w", err)
	}
	return nil
}

// ReadLatencySnapshot loads a snapshot without initializing runtime services.
func ReadLatencySnapshot(storageRoot string) (LatencySnapshot, error) {
	path := LatencySnapshotPath(storageRoot)
	data, err := os.ReadFile(path)
	if err != nil {
		return LatencySnapshot{}, fmt.Errorf("read %s: %w", path, err)
	}

	var snapshot LatencySnapshot
	if err := json.Unmarshal(data, &snapshot); err != nil {
		return LatencySnapshot{}, fmt.Errorf("invalid latency snapshot %s: %w", path, err)
	}
	if err := validateLatencySnapshot(snapshot); err != nil {
		return LatencySnapshot{}, fmt.Errorf("invalid latency snapshot %s: %w", path, err)
	}
	return snapshot, nil
}

func validateLatencySnapshot(snapshot LatencySnapshot) error {
	if snapshot.Version != LatencySnapshotVersion || snapshot.GeneratedAt.IsZero() || len(snapshot.Metrics) == 0 {
		return fmt.Errorf("missing version, generated_at, or metrics")
	}
	for _, metric := range snapshot.Metrics {
		if err := validateLatencyMetricSnapshot(metric); err != nil {
			return err
		}
	}
	return nil
}

func validateLatencyMetricSnapshot(metric LatencyMetricSnapshot) error {
	if metric.Name == "" || metric.Count < 0 {
		return fmt.Errorf("malformed metric")
	}
	if metric.Count > 0 && (metric.P50MS == nil || metric.P99MS == nil || metric.UpdatedAt.IsZero()) {
		return fmt.Errorf("measured metric missing percentiles or updated_at")
	}
	return nil
}

// LatencySnapshotPath returns the local operator snapshot path.
func LatencySnapshotPath(storageRoot string) string {
	return filepath.Join(storageRoot, "workspace", "latency.json")
}
