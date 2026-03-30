package state

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// FileLock represents an acquired lock on a workflow.
type FileLock struct {
	path string
	file *os.File
}

// AcquireLock attempts to acquire a lock for the given workflow ID.
// Returns an error if the lock cannot be acquired within the timeout.
func AcquireLock(lockDir string, id WorkflowID, timeout time.Duration) (*FileLock, error) {
	lockPath := filepath.Join(lockDir, string(id)+".lock")

	// Ensure lock directory exists.
	if err := os.MkdirAll(lockDir, 0750); err != nil {
		return nil, fmt.Errorf("creating lock directory: %w", err)
	}

	// Try to acquire lock with timeout.
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		// Try to create lock file exclusively.
		file, err := os.OpenFile(lockPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0640)
		if err == nil {
			// Lock acquired.
			return &FileLock{path: lockPath, file: file}, nil
		}

		// Lock exists, check if stale.
		if info, err := os.Stat(lockPath); err == nil {
			if time.Since(info.ModTime()) > timeout {
				// Stale lock - remove it.
				_ = os.Remove(lockPath)
				continue
			}
		}

		// Wait a bit before retrying.
		time.Sleep(100 * time.Millisecond)
	}

	return nil, fmt.Errorf("timeout acquiring lock for workflow %s", id)
}

// Release releases the lock.
func (l *FileLock) Release() error {
	if l.file != nil {
		_ = l.file.Close()
	}
	return os.Remove(l.path)
}

// CleanupStaleLocks removes lock files older than maxAge.
func CleanupStaleLocks(lockDir string, maxAge time.Duration) error {
	entries, err := os.ReadDir(lockDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("reading lock directory: %w", err)
	}

	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".lock") {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}
		if time.Since(info.ModTime()) > maxAge {
			_ = os.Remove(filepath.Join(lockDir, entry.Name()))
		}
	}

	return nil
}
