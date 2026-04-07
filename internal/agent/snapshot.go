package agent

import (
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

// CreateSnapshot captures the current session state into a history directory.
func CreateSnapshot(storageRoot string, ticket HandoffTicket) error {
	sessionDir := filepath.Join(storageRoot, ".private", "session")
	historyDir := filepath.Join(sessionDir, "history")

	// Ensure history directory exists
	if err := os.MkdirAll(historyDir, 0o755); err != nil {
		return fmt.Errorf("failed to create history dir: %w", err)
	}

	timestamp := time.Now().Format("20060102_150405")
	specialist := ticket.TargetSpecialist
	if specialist == "" {
		specialist = "unknown"
	}
	taskID := ticket.TaskID
	if taskID == "" {
		taskID = "untasked"
	}

	snapshotName := fmt.Sprintf("%s_%s_%s", timestamp, specialist, taskID)
	snapshotDir := filepath.Join(historyDir, snapshotName)

	// Check if a snapshot for this specialist/task_id already exists in the last few minutes
	// to avoid duplicates on retries.
	// Actually, the spec says "if snapshot doesn't already exist for this specialist/task_id combo, create one."
	// We can check if any existing snapshot has the same specialist and taskID.
	existing, _ := ListSnapshots(storageRoot)
	for _, s := range existing {
		if s.Specialist == specialist && s.TaskID == taskID {
			slog.Debug("snapshot: already exists for this specialist/task combo, skipping", 
				"specialist", specialist, "task_id", taskID)
			return nil
		}
	}

	if err := os.MkdirAll(snapshotDir, 0o755); err != nil {
		return fmt.Errorf("failed to create snapshot dir: %w", err)
	}

	// Files to copy
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

	// Create metadata
	meta := SnapshotMetadata{
		Timestamp:  time.Now().Format(time.RFC3339),
		Specialist: specialist,
		TaskID:     taskID,
		GitSHA:     getGitSHA(),
		Name:       snapshotName,
	}

	metaData, err := json.MarshalIndent(meta, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal metadata: %w", err)
	}

	if err := os.WriteFile(filepath.Join(snapshotDir, "snapshot_metadata.json"), metaData, 0o600); err != nil {
		return fmt.Errorf("failed to write metadata: %w", err)
	}

	slog.Info("snapshot: created checkpoint", "name", snapshotName)
	return nil
}

// ListSnapshots returns all available snapshots sorted by timestamp (newest first).
func ListSnapshots(storageRoot string) ([]SnapshotMetadata, error) {
	historyDir := filepath.Join(storageRoot, ".private", "session", "history")
	entries, err := os.ReadDir(historyDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}

	var snapshots []SnapshotMetadata
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

	// Sort newest first
	sort.Slice(snapshots, func(i, j int) bool {
		return snapshots[i].Name > snapshots[j].Name
	})

	return snapshots, nil
}

// RestoreSnapshot rolls back the session state to a specific snapshot.
func RestoreSnapshot(storageRoot, snapshotName string) error {
	sessionDir := filepath.Join(storageRoot, ".private", "session")
	historyDir := filepath.Join(sessionDir, "history")
	snapshotDir := filepath.Join(historyDir, snapshotName)

	if _, err := os.Stat(snapshotDir); err != nil {
		return fmt.Errorf("snapshot not found: %s", snapshotName)
	}

	// 1. Delete current session files (except history and archived)
	entries, err := os.ReadDir(sessionDir)
	if err != nil {
		return err
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

	// 2. Copy snapshot contents back
	snapEntries, err := os.ReadDir(snapshotDir)
	if err != nil {
		return err
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

	slog.Info("snapshot: restored state from checkpoint", "name", snapshotName)
	return nil
}

func copyFile(src, dst string) error {
	sourceFile, err := os.Open(src)
	if err != nil {
		return err
	}
	defer sourceFile.Close()

	destFile, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer destFile.Close()

	_, err = io.Copy(destFile, sourceFile)
	return err
}

func getGitSHA() string {
	cmd := exec.Command("git", "rev-parse", "HEAD")
	out, err := cmd.Output()
	if err != nil {
		return "unknown"
	}
	return strings.TrimSpace(string(out))
}
