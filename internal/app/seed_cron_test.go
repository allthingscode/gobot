//nolint:testpackage // needs unexported identifiers: indexWorkspaceJobID, indexWorkspaceJobName, indexWorkspacePayload
package app

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/cron"
)

func readJobsStore(t *testing.T, storageRoot string) cron.Store {
	t.Helper()
	path := filepath.Join(storageRoot, "workspace", "jobs.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read jobs.json: %v", err)
	}
	var store cron.Store
	if err := json.Unmarshal(data, &store); err != nil {
		t.Fatalf("decode jobs.json: %v", err)
	}
	return store
}

// Enabling vector search must yield an automatically-seeded INDEX_WORKSPACE job
// without any manual operator cron wiring (F-142 core acceptance criterion).
func TestSeedDefaultCronJobs_EnabledSeedsIndexJob(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = t.TempDir()
	cfg.Strategic.VectorSearchEnabled = true
	cfg.Strategic.VectorIndexInterval = "24h"

	SeedDefaultCronJobs(cfg)

	store := readJobsStore(t, cfg.Strategic.StorageRoot)
	job, ok := findJob(store, indexWorkspaceJobID)
	if !ok {
		t.Fatalf("expected seeded job %q, got %d jobs", indexWorkspaceJobID, len(store.Jobs))
	}
	if !job.Enabled {
		t.Error("seeded job must be enabled")
	}
	if job.Name != indexWorkspaceJobName {
		t.Errorf("name = %q, want %q", job.Name, indexWorkspaceJobName)
	}
	if job.Payload.Message != indexWorkspacePayload {
		t.Errorf("payload = %q, want %q", job.Payload.Message, indexWorkspacePayload)
	}
	if job.Schedule.Kind != cron.KindEvery {
		t.Errorf("schedule kind = %q, want %q", job.Schedule.Kind, cron.KindEvery)
	}
	const want24hMS = int64(24 * 60 * 60 * 1000)
	if job.Schedule.EveryMS == nil || *job.Schedule.EveryMS != want24hMS {
		t.Errorf("everyMs = %v, want %d", job.Schedule.EveryMS, want24hMS)
	}
}

// When vector search is disabled, no default job is seeded and operator-created
// jobs remain untouched (backward compatibility).
func TestSeedDefaultCronJobs_DisabledSeedsNothing(t *testing.T) {
	t.Parallel()
	storageRoot := t.TempDir()
	jobsDir := filepath.Join(storageRoot, "workspace")
	if err := os.MkdirAll(jobsDir, 0o755); err != nil {
		t.Fatal(err)
	}
	operatorStore := cron.Store{Jobs: []cron.Job{{ID: "operator_job", Name: "Operator", Enabled: true}}}
	data, _ := operatorStore.EncodeJSON()
	if err := os.WriteFile(filepath.Join(jobsDir, "jobs.json"), data, 0o600); err != nil {
		t.Fatal(err)
	}

	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = storageRoot
	cfg.Strategic.VectorSearchEnabled = false

	SeedDefaultCronJobs(cfg)

	store := readJobsStore(t, storageRoot)
	if _, ok := findJob(store, indexWorkspaceJobID); ok {
		t.Error("index job must not be seeded when vector search is disabled")
	}
	if _, ok := findJob(store, "operator_job"); !ok {
		t.Error("operator-created job must remain untouched")
	}
}

// Seeding is idempotent: a second call after an operator-disabled job exists
// must not overwrite the existing entry (no clobber on restart).
func TestSeedDefaultCronJobs_DoesNotClobberExisting(t *testing.T) {
	t.Parallel()
	cfg := &config.Config{}
	cfg.Strategic.StorageRoot = t.TempDir()
	cfg.Strategic.VectorSearchEnabled = true

	SeedDefaultCronJobs(cfg)
	// Operator disables the auto-seeded job; a restart must preserve that.
	store := readJobsStore(t, cfg.Strategic.StorageRoot)
	for i := range store.Jobs {
		if store.Jobs[i].ID == indexWorkspaceJobID {
			store.Jobs[i].Enabled = false
		}
	}
	data, _ := store.EncodeJSON()
	_ = os.WriteFile(filepath.Join(cfg.Strategic.StorageRoot, "workspace", "jobs.json"), data, 0o600)

	SeedDefaultCronJobs(cfg)

	store = readJobsStore(t, cfg.Strategic.StorageRoot)
	job, ok := findJob(store, indexWorkspaceJobID)
	if !ok {
		t.Fatal("job missing after re-seed")
	}
	if job.Enabled {
		t.Error("re-seed clobbered operator's disabled state")
	}
	count := 0
	for _, j := range store.Jobs {
		if j.ID == indexWorkspaceJobID {
			count++
		}
	}
	if count != 1 {
		t.Errorf("duplicate seeded jobs: got %d", count)
	}
}

func findJob(store cron.Store, id string) (cron.Job, bool) {
	for _, j := range store.Jobs {
		if j.ID == id {
			return j, true
		}
	}
	return cron.Job{}, false
}
