//nolint:testpackage // exercises unexported checkStorageSizes, fmtBytes, storageSizeStatFn seam
package doctor

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/memory/vector"
)

const testEmbeddingModel = "custom/model"

// fakeFileInfo is a minimal os.FileInfo for injecting synthetic sizes via storageSizeStatFn.
type fakeFileInfo struct{ size int64 }

func (f fakeFileInfo) Name() string       { return "" }
func (f fakeFileInfo) Size() int64        { return f.size }
func (f fakeFileInfo) Mode() os.FileMode  { return 0 }
func (f fakeFileInfo) ModTime() time.Time { return time.Time{} }
func (f fakeFileInfo) IsDir() bool        { return false }
func (f fakeFileInfo) Sys() any           { return nil }

// setupStorageRoot creates a minimal StorageRoot with workspace/ and memory/ subdirs.
func setupStorageRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	for _, sub := range []string{"workspace", "memory"} {
		if err := os.MkdirAll(filepath.Join(root, sub), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

// writeTestFile writes content to path, creating parent dirs as needed.
func writeTestFile(t *testing.T, path string, content []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, content, 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestCheckStorageSizes_AllAbsent(t *testing.T) {
	t.Parallel()
	root := setupStorageRoot(t)
	r := checkStorageSizes(cfgWithRoot(root))
	if !r.OK {
		t.Errorf("all-absent should be OK, got OK=%v detail=%q", r.OK, r.Detail)
	}
	if r.Critical {
		t.Error("storage sizes must be non-critical")
	}
	for _, want := range []string{"checkpoints 0 B", "vectors 0 B", "audit 0 B"} {
		if !strings.Contains(r.Detail, want) {
			t.Errorf("detail %q missing %q", r.Detail, want)
		}
	}
}

func TestCheckStorageSizes_BelowThreshold(t *testing.T) {
	t.Parallel()
	root := setupStorageRoot(t)
	writeTestFile(t, filepath.Join(root, "workspace", "checkpoints.db"), []byte("x"))
	r := checkStorageSizes(cfgWithRoot(root))
	if !r.OK {
		t.Errorf("1-byte checkpoints.db should be OK, got OK=%v detail=%q", r.OK, r.Detail)
	}
	if r.Critical {
		t.Error("storage sizes must be non-critical")
	}
}

func TestCheckStorageSizes_CheckpointsWAL(t *testing.T) {
	t.Parallel()
	root := setupStorageRoot(t)
	walContent := []byte("x") // 1 byte — any non-zero WAL must produce +wal token
	writeTestFile(t, filepath.Join(root, "workspace", "checkpoints.db"), []byte("x"))
	writeTestFile(t, filepath.Join(root, "workspace", "checkpoints.db-wal"), walContent)
	r := checkStorageSizes(cfgWithRoot(root))
	if !strings.Contains(r.Detail, "+wal") {
		t.Errorf("expected +wal token in detail, got %q", r.Detail)
	}
}

func TestCheckStorageSizes_WALAbsent(t *testing.T) {
	t.Parallel()
	root := setupStorageRoot(t)
	writeTestFile(t, filepath.Join(root, "workspace", "checkpoints.db"), []byte("x"))
	r := checkStorageSizes(cfgWithRoot(root))
	if strings.Contains(r.Detail, "+wal") {
		t.Errorf("absent WAL must not produce +wal token, got %q", r.Detail)
	}
}

func TestCheckStorageSizes_UsesConfiguredVectorCache(t *testing.T) {
	t.Parallel()
	root := setupStorageRoot(t)
	cfg := cfgWithRoot(root)
	cfg.Runtime.EmbeddingModel = testEmbeddingModel
	cacheName := vector.CacheFilename(cfg.EmbeddingModel())
	writeTestFile(t, filepath.Join(root, "memory", cacheName), []byte("abc"))
	writeTestFile(t, filepath.Join(root, "memory", cacheName+"-wal"), []byte("de"))
	writeTestFile(t, filepath.Join(root, "memory", "vectors.db"), []byte("legacy cache must be excluded"))

	r := checkStorageSizes(cfg)
	if !r.OK {
		t.Fatalf("configured vector cache should be OK, got detail=%q", r.Detail)
	}
	if !strings.Contains(r.Detail, "vectors 3 B (+wal 2 B)") {
		t.Errorf("detail should report active vector cache and WAL, got %q", r.Detail)
	}
}

//nolint:paralleltest // mutates the package-global storageSizeStatFn seam; must not run concurrently with other storage-size tests
func TestCheckStorageSizes_AboveThreshold(t *testing.T) {
	orig := storageSizeStatFn
	t.Cleanup(func() { storageSizeStatFn = orig })

	bigSize := storageSizeWarnBytes + 1
	storageSizeStatFn = func(path string) (os.FileInfo, error) {
		if strings.HasSuffix(path, "checkpoints.db") {
			return fakeFileInfo{size: bigSize}, nil
		}
		return nil, os.ErrNotExist
	}

	root := setupStorageRoot(t)
	r := checkStorageSizes(cfgWithRoot(root))
	if r.OK {
		t.Error("above-threshold must be advisory WARN (OK=false)")
	}
	if r.Critical {
		t.Error("storage sizes must remain non-critical")
	}
	if r.Remediation == "" {
		t.Error("above-threshold must carry a remediation")
	}
	if !strings.Contains(r.Detail, "checkpoints") {
		t.Errorf("detail must name the offending store, got %q", r.Detail)
	}
}

//nolint:paralleltest // mutates the package-global storageSizeStatFn seam
func TestCheckStorageSizes_ActiveVectorCacheAboveThreshold(t *testing.T) {
	orig := storageSizeStatFn
	t.Cleanup(func() { storageSizeStatFn = orig })

	cfg := cfgWithRoot(setupStorageRoot(t))
	cfg.Runtime.EmbeddingModel = testEmbeddingModel
	activeCache := vector.CacheFilename(cfg.EmbeddingModel())
	storageSizeStatFn = func(path string) (os.FileInfo, error) {
		if strings.HasSuffix(path, activeCache) {
			return fakeFileInfo{size: storageSizeWarnBytes + 1}, nil
		}
		return nil, os.ErrNotExist
	}

	r := checkStorageSizes(cfg)
	if r.OK {
		t.Error("active vector cache above threshold must be advisory WARN")
	}
	if !strings.Contains(r.Remediation, "vectors is large") {
		t.Errorf("remediation should identify logical vectors store, got %q", r.Remediation)
	}
	if strings.Contains(r.Remediation, activeCache) {
		t.Errorf("remediation must not expose physical cache %q, got %q", activeCache, r.Remediation)
	}
}

func TestCheckStorageSizes_SessionsFilesCount(t *testing.T) {
	t.Parallel()
	root := setupStorageRoot(t)
	sessDir := filepath.Join(root, "workspace", "sessions", "2026-01-01")
	if err := os.MkdirAll(sessDir, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"a.md", "b.md", "c.md"} {
		writeTestFile(t, filepath.Join(sessDir, name), []byte("content"))
	}
	r := checkStorageSizes(cfgWithRoot(root))
	if !strings.Contains(r.Detail, "(3 files)") {
		t.Errorf("expected (3 files) in detail, got %q", r.Detail)
	}
}

func TestFmtBytes_Formatting(t *testing.T) {
	t.Parallel()
	cases := []struct {
		n    int64
		want string
	}{
		{0, "0 B"},
		{512, "512 B"},
		{2048, "2 KiB"},
		{1 << 20, "1.0 MiB"},
		{5 * (1 << 20), "5.0 MiB"},
	}
	for _, tc := range cases {
		if got := fmtBytes(tc.n); got != tc.want {
			t.Errorf("fmtBytes(%d) = %q, want %q", tc.n, got, tc.want)
		}
	}
}
