package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// SnapshotMetadata contains info about a session snapshot.
type SnapshotMetadata struct {
	Timestamp  string `json:"timestamp"`
	Specialist string `json:"specialist"`
	TaskID     string `json:"task_id"`
	GitSHA     string `json:"git_sha"`
	Name       string `json:"name"` // directory name
}

// rewindHistoryDir returns the canonical location for session snapshots:
// {storageRoot}/state/rewind/. This replaced the legacy in-tree-factory
// path {storageRoot}/.private/session/history/.
func rewindHistoryDir(storageRoot string) string {
	return filepath.Join(storageRoot, "state", "rewind")
}

// legacyRewindHistoryDir returns the pre-Crucible snapshot location, kept
// as a read-only fallback so existing snapshots remain restorable for one
// release. Remove when all known installs have migrated.
func legacyRewindHistoryDir(storageRoot string) string {
	return filepath.Join(storageRoot, ".private", "session", "history")
}

// sessionSourceDir returns the directory snapshots are copied from and
// restored into. Still the legacy in-tree-factory session dir; it will
// move in the follow-up that retires NewHandoffHook.
func sessionSourceDir(storageRoot string) string {
	return filepath.Join(storageRoot, ".private", "session")
}

// CreateSnapshot captures the current session state into a history directory.
func CreateSnapshot(storageRoot string, ticket HandoffTicket) error {
	sessionDir := sessionSourceDir(storageRoot)
	historyDir := rewindHistoryDir(storageRoot)

	if err := os.MkdirAll(historyDir, 0o755); err != nil {
		return fmt.Errorf("failed to create history dir: %w", err)
	}

	specialist, taskID := resolveHandoffMetadata(ticket)
	if shouldSkipSnapshot(storageRoot, specialist, taskID) {
		return nil
	}

	timestamp := time.Now().Format("20060102_150405")
	snapshotName := fmt.Sprintf("%s_%s_%s", timestamp, specialist, taskID)
	snapshotDir := filepath.Join(historyDir, snapshotName)

	if err := os.MkdirAll(snapshotDir, 0o755); err != nil {
		return fmt.Errorf("failed to create snapshot dir: %w", err)
	}

	copySessionFiles(sessionDir, snapshotDir)
	if err := writeSnapshotMetadata(snapshotDir, snapshotName, specialist, taskID); err != nil {
		return fmt.Errorf("write snapshot metadata: %w", err)
	}

	slog.Info("snapshot: created checkpoint", "name", snapshotName)
	return nil
}

const (
	unknownSpecialist = "unknown"
	untaskedID        = "untasked"
)

func resolveHandoffMetadata(ticket HandoffTicket) (specialist, taskID string) {
	specialist = ticket.TargetSpecialist
	if specialist == "" {
		specialist = unknownSpecialist
	}
	taskID = ticket.TaskID
	if taskID == "" {
		taskID = untaskedID
	}
	return
}

func shouldSkipSnapshot(storageRoot, specialist, taskID string) bool {
	existing, _ := ListSnapshots(storageRoot)
	for _, s := range existing {
		if s.Specialist == specialist && s.TaskID == taskID {
			slog.Debug("snapshot: already exists for this specialist/task combo, skipping",
				"specialist", specialist, "task_id", taskID)
			return true
		}
	}
	return false
}

func copySessionFiles(sessionDir, snapshotDir string) {
	filesToCopy := []string{"session_state.json", "task.md", "review_report.md"}
	for _, f := range filesToCopy {
		src := filepath.Join(sessionDir, f)
		dst := filepath.Join(snapshotDir, f)
		if err := copyFile(src, dst); err != nil {
			if !os.IsNotExist(err) {
				slog.Warn("snapshot: failed to copy file", "file", f, "err", err)
			}
		}
	}
}

func writeSnapshotMetadata(snapshotDir, name, specialist, taskID string) error {
	meta := SnapshotMetadata{
		Timestamp:  time.Now().Format(time.RFC3339),
		Specialist: specialist,
		TaskID:     taskID,
		GitSHA:     getGitSHA(),
		Name:       name,
	}

	metaData, err := json.MarshalIndent(meta, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal metadata: %w", err)
	}

	if err := os.WriteFile(filepath.Join(snapshotDir, "snapshot_metadata.json"), metaData, 0o600); err != nil {
		return fmt.Errorf("failed to write metadata: %w", err)
	}
	return nil
}

// ListSnapshots returns all available snapshots sorted by timestamp (newest first).
// Reads the canonical location ({storageRoot}/state/rewind/) and the legacy
// pre-Crucible location ({storageRoot}/.private/session/history/); if the
// legacy dir contains anything, emits a one-time warning so users migrate.
func ListSnapshots(storageRoot string) ([]SnapshotMetadata, error) {
	snapshots, err := readSnapshotDir(rewindHistoryDir(storageRoot))
	if err != nil {
		return nil, err
	}

	legacy, err := readSnapshotDir(legacyRewindHistoryDir(storageRoot))
	if err != nil {
		return nil, err
	}
	if len(legacy) > 0 {
		slog.Warn("rewind: found snapshots at legacy path, please migrate",
			"legacy_path", legacyRewindHistoryDir(storageRoot),
			"new_path", rewindHistoryDir(storageRoot),
			"count", len(legacy))
		snapshots = append(snapshots, legacy...)
	}

	// Sort newest first
	sort.Slice(snapshots, func(i, j int) bool {
		return snapshots[i].Name > snapshots[j].Name
	})

	return snapshots, nil
}

func readSnapshotDir(historyDir string) ([]SnapshotMetadata, error) {
	entries, err := os.ReadDir(historyDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("list snapshots dir: %w", err)
	}

	snapshots := make([]SnapshotMetadata, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		metaPath := filepath.Join(historyDir, entry.Name(), "snapshot_metadata.json")
		data, err := os.ReadFile(metaPath)
		if err != nil {
			continue
		}
		var meta SnapshotMetadata
		if err := json.Unmarshal(data, &meta); err != nil {
			continue
		}
		meta.Name = entry.Name()
		snapshots = append(snapshots, meta)
	}
	return snapshots, nil
}

func deleteSessionFilesForRestore(sessionDir string) error {
	entries, err := os.ReadDir(sessionDir)
	if err != nil {
		return fmt.Errorf("read dir: %w", err)
	}
	for _, entry := range entries {
		name := entry.Name()
		if name == "history" || name == "archived" || name == "recovery" {
			continue
		}
		if err := os.RemoveAll(filepath.Join(sessionDir, name)); err != nil {
			slog.Warn("restore: failed to remove file", "name", name, "err", err)
		}
	}
	return nil
}

func copySnapshotContents(snapshotDir, sessionDir string) error {
	snapEntries, err := os.ReadDir(snapshotDir)
	if err != nil {
		return fmt.Errorf("read snapshot dir: %w", err)
	}
	for _, entry := range snapEntries {
		if entry.Name() == "snapshot_metadata.json" {
			continue
		}
		src := filepath.Join(snapshotDir, entry.Name())
		dst := filepath.Join(sessionDir, entry.Name())
		if err := copyFile(src, dst); err != nil {
			return fmt.Errorf("failed to restore %s: %w", entry.Name(), err)
		}
	}
	return nil
}

// RestoreSnapshot overwrites the current session state with the contents of a named snapshot.
// Looks for the snapshot at the canonical {storageRoot}/state/rewind/ first,
// then falls back to the legacy {storageRoot}/.private/session/history/ path.
func RestoreSnapshot(storageRoot, snapshotName string) error {
	sessionDir := sessionSourceDir(storageRoot)
	snapshotDir := filepath.Join(rewindHistoryDir(storageRoot), snapshotName)
	if _, err := os.Stat(snapshotDir); err != nil {
		legacyDir := filepath.Join(legacyRewindHistoryDir(storageRoot), snapshotName)
		if _, legacyErr := os.Stat(legacyDir); legacyErr != nil {
			return fmt.Errorf("snapshot not found: %s", snapshotName)
		}
		snapshotDir = legacyDir
	}

	if err := deleteSessionFilesForRestore(sessionDir); err != nil {
		return fmt.Errorf("delete session files: %w", err)
	}

	if err := copySnapshotContents(snapshotDir, sessionDir); err != nil {
		return fmt.Errorf("copy snapshot contents: %w", err)
	}

	slog.Info("snapshot: restored state from checkpoint", "name", snapshotName)
	return nil
}

func copyFile(src, dst string) error {
	sourceFile, err := os.Open(src)
	if err != nil {
		return fmt.Errorf("open source file: %w", err)
	}
	defer func() { _ = sourceFile.Close() }()

	destFile, err := os.Create(dst)
	if err != nil {
		return fmt.Errorf("create dest file: %w", err)
	}
	defer func() { _ = destFile.Close() }()

	if _, err = io.Copy(destFile, sourceFile); err != nil {
		return fmt.Errorf("copy file: %w", err)
	}
	return nil
}

func getGitSHA() string {
	// Use background context for git call as this is a non-critical metadata fetch.
	cmd := exec.CommandContext(context.Background(), "git", "rev-parse", "HEAD")
	out, err := cmd.Output()
	if err != nil {
		return unknownSpecialist
	}
	return strings.TrimSpace(string(out))
}
