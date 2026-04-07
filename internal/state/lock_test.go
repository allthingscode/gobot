package state

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestAcquireLock_Success(t *testing.T) {
	tempDir := t.TempDir()
	lock, err := AcquireLock(tempDir, "wf-123", 5*time.Second)
	if err != nil {
		t.Fatalf("AcquireLock failed: %v", err)
	}
	defer func() { _ = lock.Release() }()

	// Verify lock file exists.
	lockPath := filepath.Join(tempDir, "wf-123.lock")
	if _, err := os.Stat(lockPath); err != nil {
		t.Errorf("Lock file does not exist: %v", err)
	}
}

func TestAcquireLock_Timeout(t *testing.T) {
	tempDir := t.TempDir()
	// First acquire the lock.
	lock1, err := AcquireLock(tempDir, "wf-456", 5*time.Second)
	if err != nil {
		t.Fatalf("First AcquireLock failed: %v", err)
	}
	defer func() { _ = lock1.Release() }()

	// Second acquire should timeout quickly.
	_, err = AcquireLock(tempDir, "wf-456", 100*time.Millisecond)
	if err == nil {
		t.Error("Expected timeout error, got nil")
	}
}

func TestAcquireLock_StaleLock(t *testing.T) {
	tempDir := t.TempDir()
	lockPath := filepath.Join(tempDir, "wf-789.lock")

	// Create an old lock file.
	if err := os.WriteFile(lockPath, []byte{}, 0o600); err != nil {
		t.Fatalf("Failed to create stale lock: %v", err)
	}

	// Set modification time to the past.
	oldTime := time.Now().Add(-time.Hour)
	if err := os.Chtimes(lockPath, oldTime, oldTime); err != nil {
		t.Fatalf("Failed to set lock time: %v", err)
	}

	// Should be able to acquire despite existing file (stale).
	lock, err := AcquireLock(tempDir, "wf-789", 5*time.Second)
	if err != nil {
		t.Fatalf("AcquireLock failed on stale lock: %v", err)
	}
	_ = lock.Release()
}

func TestFileLock_Release(t *testing.T) {
	tempDir := t.TempDir()
	lock, err := AcquireLock(tempDir, "wf-abc", 5*time.Second)
	if err != nil {
		t.Fatalf("AcquireLock failed: %v", err)
	}

	lockPath := filepath.Join(tempDir, "wf-abc.lock")

	// Release the lock.
	if err := lock.Release(); err != nil {
		t.Errorf("Release failed: %v", err)
	}

	// Verify lock file is removed.
	if _, err := os.Stat(lockPath); !os.IsNotExist(err) {
		t.Error("Lock file should be removed after Release")
	}
}

func TestCleanupStaleLocks(t *testing.T) {
	tempDir := t.TempDir()

	// Create a fresh lock.
	freshLock := filepath.Join(tempDir, "fresh.lock")
	if err := os.WriteFile(freshLock, []byte{}, 0o600); err != nil {
		t.Fatalf("Failed to create fresh lock: %v", err)
	}

	// Create a stale lock.
	staleLock := filepath.Join(tempDir, "stale.lock")
	if err := os.WriteFile(staleLock, []byte{}, 0o600); err != nil {
		t.Fatalf("Failed to create stale lock: %v", err)
	}
	oldTime := time.Now().Add(-time.Hour)
	_ = os.Chtimes(staleLock, oldTime, oldTime)

	// Cleanup locks older than 30 minutes.
	if err := CleanupStaleLocks(tempDir, 30*time.Minute); err != nil {
		t.Fatalf("CleanupStaleLocks failed: %v", err)
	}

	// Fresh lock should remain.
	if _, err := os.Stat(freshLock); err != nil {
		t.Error("Fresh lock should not be cleaned up")
	}

	// Stale lock should be removed.
	if _, err := os.Stat(staleLock); !os.IsNotExist(err) {
		t.Error("Stale lock should be cleaned up")
	}
}
