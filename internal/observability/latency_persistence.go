package observability

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

const LatencySnapshotVersion = 1

// WriteLatencySnapshot persists the compact latency snapshot under workspace.
func WriteLatencySnapshot(storageRoot string, snapshot LatencySnapshot) error {
	path := LatencySnapshotPath(storageRoot)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create latency snapshot directory: %w", err)
	}

	data, err := json.MarshalIndent(snapshot, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal latency snapshot: %w", err)
	}
	data = append(data, '\n')

	tmp, err := os.CreateTemp(filepath.Dir(path), ".latency-*.tmp")
	if err != nil {
		return fmt.Errorf("create latency snapshot temp file: %w", err)
	}
	tmpName := tmp.Name()
	cleanup := true
	defer func() {
		if cleanup {
			_ = os.Remove(tmpName)
		}
	}()

	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("write latency snapshot temp file: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close latency snapshot temp file: %w", err)
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("remove previous latency snapshot: %w", err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		return fmt.Errorf("replace latency snapshot: %w", err)
	}
	cleanup = false
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
