//nolint:testpackage // covers package-private state helpers
package state

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSavePageConstraintSignalValidationAndSanitizing(t *testing.T) {
	t.Parallel()

	if err := SavePageConstraintSignal("", "session", "auth", "login"); err == nil || !strings.Contains(err.Error(), "storage root is required") {
		t.Fatalf("expected storage root validation error, got %v", err)
	}
	if err := SavePageConstraintSignal(t.TempDir(), "", "auth", "login"); err == nil || !strings.Contains(err.Error(), "session key is required") {
		t.Fatalf("expected session key validation error, got %v", err)
	}

	root := t.TempDir()
	if err := SavePageConstraintSignal(root, "cron:email/user one", " auth_required ", " login form "); err != nil {
		t.Fatalf("SavePageConstraintSignal: %v", err)
	}
	var signal PageConstraintSignal
	path := filepath.Join(root, "state", "page_constraints", "cron_email_user_one.json")
	if err := ReadFileJSON(path, &signal); err != nil {
		t.Fatalf("ReadFileJSON: %v", err)
	}
	if signal.SessionKey != "cron:email/user one" || signal.Classification != "auth_required" || signal.LastBlockingSignal != "login form" {
		t.Fatalf("unexpected signal: %#v", signal)
	}
}

func TestWriteFileJSONMarshalError(t *testing.T) {
	t.Parallel()

	err := WriteFileJSON(filepath.Join(t.TempDir(), "bad.json"), map[string]any{"bad": make(chan int)}, 0o600)
	if err == nil || !strings.Contains(err.Error(), "marshaling JSON") {
		t.Fatalf("expected marshal error, got %v", err)
	}
}

func TestCleanupStaleLocksSkipsNonLocksAndMissingDir(t *testing.T) {
	t.Parallel()

	if err := CleanupStaleLocks(filepath.Join(t.TempDir(), "missing"), time.Second); err != nil {
		t.Fatalf("missing lock dir should be ignored: %v", err)
	}

	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "nested.lock"), 0o750); err != nil {
		t.Fatalf("mkdir nested.lock: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "note.txt"), []byte("keep"), 0o600); err != nil {
		t.Fatalf("write note: %v", err)
	}
	if err := CleanupStaleLocks(dir, 0); err != nil {
		t.Fatalf("CleanupStaleLocks: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "note.txt")); err != nil {
		t.Fatalf("non-lock file should remain: %v", err)
	}
}
