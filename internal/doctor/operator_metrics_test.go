//nolint:testpackage // exercises operator metric helpers and package-private fixtures
package doctor

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/cron"
)

func TestReadStartupSnapshot(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	readyAt := time.Date(2026, 7, 9, 10, 11, 12, 0, time.UTC)
	writeStartupJSON(t, root, `{"version":1,"ready_at":"`+readyAt.Format(time.RFC3339Nano)+`","duration_ms":987}`)

	snapshot, err := ReadStartupSnapshot(root)
	if err != nil {
		t.Fatalf("ReadStartupSnapshot: %v", err)
	}
	if snapshot.DurationMS != 987 {
		t.Fatalf("DurationMS = %d, want 987", snapshot.DurationMS)
	}
	if !strings.Contains(snapshot.ReadyAt, "2026-07-09 10:11:12") {
		t.Fatalf("ReadyAt = %q, want formatted timestamp", snapshot.ReadyAt)
	}
}

func TestCollectStorageSizeSummary(t *testing.T) {
	t.Parallel()
	root := setupStorageRoot(t)
	writeTestFile(t, filepath.Join(root, "workspace", "checkpoints.db"), []byte("abc"))
	writeTestFile(t, filepath.Join(root, "workspace", "checkpoints.db-wal"), []byte("de"))
	writeTestFile(t, filepath.Join(root, "memory", "vectors.db"), []byte("fghi"))
	writeTestFile(t, filepath.Join(root, "workspace", "sessions", "a.md"), []byte("j"))
	writeTestFile(t, filepath.Join(root, "logs", "gobot.log"), []byte("klm"))

	summary, err := CollectStorageSizeSummary(root)
	if err != nil {
		t.Fatalf("CollectStorageSizeSummary: %v", err)
	}
	if got, want := summary.TotalBytes(), int64(13); got != want {
		t.Fatalf("TotalBytes = %d, want %d", got, want)
	}
	if len(summary.Stores) != 5 {
		t.Fatalf("Stores len = %d, want 5", len(summary.Stores))
	}
	if summary.WarnThresholdBytes != storageSizeWarnBytes {
		t.Fatalf("WarnThresholdBytes = %d, want %d", summary.WarnThresholdBytes, storageSizeWarnBytes)
	}
	checkpoints := summary.Stores[0]
	if checkpoints.Name != "checkpoints" || checkpoints.TotalBytes() != 5 {
		t.Fatalf("checkpoints store = %+v, want total 5", checkpoints)
	}
	sessions := summary.Stores[3]
	if sessions.FileCount != 1 {
		t.Fatalf("sessions FileCount = %d, want 1", sessions.FileCount)
	}
}

//nolint:paralleltest // mutates storageSizeStatFn
func TestCollectStorageSizeSummaryWarnsAboveThreshold(t *testing.T) {
	orig := storageSizeStatFn
	t.Cleanup(func() { storageSizeStatFn = orig })

	storageSizeStatFn = func(path string) (os.FileInfo, error) {
		if strings.HasSuffix(path, "vectors.db") {
			return fakeFileInfo{size: storageSizeWarnBytes + 1}, nil
		}
		return nil, os.ErrNotExist
	}

	summary, err := CollectStorageSizeSummary(setupStorageRoot(t))
	if err != nil {
		t.Fatalf("CollectStorageSizeSummary: %v", err)
	}
	for _, store := range summary.Stores {
		if store.Name == "vectors" {
			if !store.Warn {
				t.Fatal("vectors store should warn above threshold")
			}
			return
		}
	}
	t.Fatal("vectors store not found")
}

func TestReadCronHealth(t *testing.T) {
	t.Parallel()
	const nowMS = int64(1_000_000)
	root := t.TempDir()
	writeJobsJSON(t, root, []cron.Job{
		{Name: "healthy", State: cron.JobState{NextRunAtMS: nowMS + 5_000}},
		{Name: "older-fail", State: cron.JobState{FailureCount: 1, LastRunAtMS: 100}},
		{Name: "recent-fail", State: cron.JobState{FailureCount: 2, LastRunAtMS: 200}},
	})

	summary, err := ReadCronHealth(root, nowMS)
	if err != nil {
		t.Fatalf("ReadCronHealth: %v", err)
	}
	if summary.JobCount != 3 || summary.FailingCount != 2 {
		t.Fatalf("summary counts = %+v, want 3 jobs and 2 failing", summary)
	}
	if summary.LastFailureName != "recent-fail" {
		t.Fatalf("LastFailureName = %q, want recent-fail", summary.LastFailureName)
	}
	if summary.NextRunSummary != "in 5s" {
		t.Fatalf("NextRunSummary = %q, want in 5s", summary.NextRunSummary)
	}
}

func TestReadCronHealthMissingJobsFile(t *testing.T) {
	t.Parallel()
	summary, err := ReadCronHealth(t.TempDir(), time.Now().UnixMilli())
	if err != nil {
		t.Fatalf("ReadCronHealth missing file: %v", err)
	}
	if summary.JobCount != 0 || summary.NextRunSummary != "none scheduled" {
		t.Fatalf("summary = %+v, want no jobs", summary)
	}
}

func TestReadCronHealthCorruptJobsFile(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	ws := filepath.Join(root, "workspace")
	if err := os.MkdirAll(ws, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(ws, "jobs.json"), []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}

	if _, err := ReadCronHealth(root, time.Now().UnixMilli()); err == nil {
		t.Fatal("ReadCronHealth should reject corrupt jobs.json")
	}
}
