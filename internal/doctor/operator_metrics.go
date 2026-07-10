package doctor

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/allthingscode/gobot/internal/cron"
)

// StartupSnapshot is the typed dashboard/operator view of workspace/startup.json.
type StartupSnapshot struct {
	ReadyAt    string
	DurationMS int64
}

// ReadStartupSnapshot reads the persisted startup marker without initializing services.
func ReadStartupSnapshot(storageRoot string) (StartupSnapshot, error) {
	marker, err := readStartupMarker(storageRoot)
	if err != nil {
		return StartupSnapshot{}, err
	}
	return StartupSnapshot{
		ReadyAt:    marker.ReadyAt.Format("2006-01-02 15:04:05 MST"),
		DurationMS: marker.DurationMS,
	}, nil
}

// StorageStoreSize is one read-only storage footprint measurement.
type StorageStoreSize struct {
	Name      string
	Bytes     int64
	WALBytes  int64
	FileCount int
	Warn      bool
}

// TotalBytes returns the main size plus any WAL size.
func (s StorageStoreSize) TotalBytes() int64 {
	return s.Bytes + s.WALBytes
}

// StorageSizeSummary is the typed dashboard/operator view of local storage size.
type StorageSizeSummary struct {
	Stores             []StorageStoreSize
	WarnThresholdBytes int64
}

// TotalBytes returns the combined measured storage footprint.
func (s StorageSizeSummary) TotalBytes() int64 {
	var total int64
	for _, store := range s.Stores {
		total += store.TotalBytes()
	}
	return total
}

// CollectStorageSizeSummary reports storage sizes using the same read-only probe
// semantics as gobot doctor.
func CollectStorageSizeSummary(storageRoot string) (StorageSizeSummary, error) {
	ws := filepath.Join(storageRoot, "workspace")
	mem := filepath.Join(storageRoot, "memory")

	ckptDB, ckptWAL, err := collectDBSize(filepath.Join(ws, "checkpoints.db"), filepath.Join(ws, "checkpoints.db-wal"))
	if err != nil {
		return StorageSizeSummary{}, fmt.Errorf("checkpoints.db: %w", err)
	}
	auditDB, auditWAL, err := collectDBSize(filepath.Join(ws, "audit.db"), filepath.Join(ws, "audit.db-wal"))
	if err != nil {
		return StorageSizeSummary{}, fmt.Errorf("audit.db: %w", err)
	}
	vecDB, vecWAL, err := collectDBSize(filepath.Join(mem, "vectors.db"), filepath.Join(mem, "vectors.db-wal"))
	if err != nil {
		return StorageSizeSummary{}, fmt.Errorf("vectors.db: %w", err)
	}
	sessBytes, sessCount, err := dirSize(filepath.Join(ws, "sessions"))
	if err != nil {
		return StorageSizeSummary{}, fmt.Errorf("sessions/: %w", err)
	}
	logsBytes, _, err := dirSize(filepath.Join(storageRoot, "logs"))
	if err != nil {
		return StorageSizeSummary{}, fmt.Errorf("logs/: %w", err)
	}

	summary := StorageSizeSummary{
		WarnThresholdBytes: storageSizeWarnBytes,
		Stores: []StorageStoreSize{
			{Name: "checkpoints", Bytes: ckptDB, WALBytes: ckptWAL},
			{Name: "vectors", Bytes: vecDB, WALBytes: vecWAL},
			{Name: "audit", Bytes: auditDB, WALBytes: auditWAL},
			{Name: "sessions", Bytes: sessBytes, FileCount: sessCount},
			{Name: "logs", Bytes: logsBytes},
		},
	}
	for i := range summary.Stores {
		summary.Stores[i].Warn = summary.Stores[i].TotalBytes() > storageSizeWarnBytes
	}
	return summary, nil
}

// CronHealthSummary is the typed dashboard/operator view of persisted cron health.
type CronHealthSummary struct {
	JobCount        int
	FailingCount    int
	LastFailureName string
	NextRunSummary  string
}

// ReadCronHealth reads workspace/jobs.json without starting a scheduler.
func ReadCronHealth(storageRoot string, nowMS int64) (CronHealthSummary, error) {
	path := filepath.Join(storageRoot, "workspace", "jobs.json")
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return CronHealthSummary{NextRunSummary: "none scheduled"}, nil
		}
		return CronHealthSummary{}, fmt.Errorf("read %s: %w", path, err)
	}

	var store cron.Store
	if err := store.DecodeJSON(data); err != nil {
		return CronHealthSummary{}, fmt.Errorf("parse %s: %w", path, err)
	}

	summary := CronHealthSummary{
		JobCount:       len(store.Jobs),
		NextRunSummary: nextRunSummary(store.Jobs, nowMS),
	}
	for _, job := range store.Jobs {
		if job.State.FailureCount == 0 {
			continue
		}
		summary.FailingCount++
		if summary.LastFailureName == "" || job.State.LastRunAtMS > lastFailureMS(store.Jobs, summary.LastFailureName) {
			summary.LastFailureName = job.Name
		}
	}
	return summary, nil
}

func lastFailureMS(jobs []cron.Job, name string) int64 {
	for _, job := range jobs {
		if job.Name == name {
			return job.State.LastRunAtMS
		}
	}
	return 0
}
