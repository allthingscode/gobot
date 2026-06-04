package cron

import (
	"fmt"
	"os"
	"path/filepath"
)

// SeedJob ensures a job with the given id exists in the jobs.json store at
// storePath, creating the store (and parent directory) if necessary. If a job
// with the same id is already present, the store is left unchanged and seeded
// reports false. This lets bootstrap install a default recurring job exactly
// once without clobbering operator edits or accumulated job state on restart.
func SeedJob(storePath string, job Job) (seeded bool, err error) {
	store, err := loadStoreForSeed(storePath)
	if err != nil {
		return false, err
	}

	for i := range store.Jobs {
		if store.Jobs[i].ID == job.ID {
			return false, nil
		}
	}

	store.Jobs = append(store.Jobs, job)

	data, err := store.EncodeJSON()
	if err != nil {
		return false, err
	}
	if mkErr := os.MkdirAll(filepath.Dir(storePath), 0o755); mkErr != nil {
		return false, fmt.Errorf("create jobs dir: %w", mkErr)
	}
	if writeErr := os.WriteFile(storePath, data, 0o600); writeErr != nil {
		return false, fmt.Errorf("write jobs.json: %w", writeErr)
	}
	return true, nil
}

func loadStoreForSeed(storePath string) (*Store, error) {
	data, err := os.ReadFile(storePath)
	if err != nil {
		if os.IsNotExist(err) {
			return &Store{}, nil
		}
		return nil, fmt.Errorf("read jobs.json: %w", err)
	}
	store := &Store{}
	if decErr := store.DecodeJSON(data); decErr != nil {
		return nil, decErr
	}
	return store, nil
}

// EveryJob constructs a recurring interval-based ("every") job suitable for
// seeding. intervalMS is the run interval in milliseconds.
func EveryJob(id, name, message string, intervalMS int64) Job {
	return Job{
		ID:      id,
		Name:    name,
		Enabled: true,
		Schedule: Schedule{
			Kind:    KindEvery,
			EveryMS: ptr(intervalMS),
		},
		Payload: Payload{
			ID:      id,
			Message: message,
		},
	}
}
