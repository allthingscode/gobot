//nolint:testpackage // exercises deterministic private collection reader
package vector

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/philippgille/chromem-go"
)

// noopEmbedder returns a fixed-length zero vector.
func noopEmbedder(_ context.Context, _ string) ([]float32, error) {
	return make([]float32, 128), nil
}

func TestIndexWorkspaceMarkdown(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	tempDir := t.TempDir()

	wsDir := setupMockWorkspace(t, tempDir)

	dbPath := filepath.Join(tempDir, "vector.db")
	store, err := NewStore(dbPath)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}

	var embedFunc chromem.EmbeddingFunc = noopEmbedder

	if err := IndexWorkspaceMarkdown(ctx, store, wsDir, embedFunc); err != nil {
		t.Fatalf("IndexWorkspaceMarkdown: %v", err)
	}

	verifyIndexedContent(t, ctx, store, embedFunc)
}

func setupMockWorkspace(t *testing.T, tempDir string) string {
	t.Helper()
	wsDir := filepath.Join(tempDir, "workspace")
	files := map[string]string{
		"README.md":           "# Readme\nContent here.",
		"docs/setup.md":       "# Setup\nStep 1.",
		"vendor/dep.md":       "should skip",
		".private/secret.md":  "should skip",
		"node_modules/mod.md": "should skip",
		"not-md.txt":          "should skip",
	}

	for path, content := range files {
		fullPath := filepath.Join(wsDir, path)
		if err := os.MkdirAll(filepath.Dir(fullPath), 0o700); err != nil {
			t.Fatalf("mkdir %s: %v", filepath.Dir(fullPath), err)
		}
		if err := os.WriteFile(fullPath, []byte(content), 0o600); err != nil {
			t.Fatalf("write file %s: %v", fullPath, err)
		}
	}
	return wsDir
}

func verifyIndexedContent(t *testing.T, ctx context.Context, store *Store, embedFunc chromem.EmbeddingFunc) {
	t.Helper()
	results, err := store.Search(ctx, "workspace_docs", "Readme", 10, nil, embedFunc)
	if err != nil {
		t.Fatalf("Search: %v", err)
	}

	if len(results) != 2 {
		t.Errorf("expected 2 documents indexed, got %d", len(results))
	}

	sources := make(map[string]bool)
	for _, r := range results {
		sources[r.Metadata["source"]] = true
	}

	if !sources["README.md"] {
		t.Error("expected README.md to be indexed")
	}
	if !sources[filepath.Join("docs", "setup.md")] {
		t.Error("expected docs/setup.md to be indexed")
	}
}

func TestIndexWorkspaceMarkdown_EmptyDir(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	tempDir := t.TempDir()
	wsDir := filepath.Join(tempDir, "empty")
	if err := os.MkdirAll(wsDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	dbPath := filepath.Join(tempDir, "vector.db")
	store, _ := NewStore(dbPath)

	if err := IndexWorkspaceMarkdown(ctx, store, wsDir, noopEmbedder); err != nil {
		t.Errorf("expected no error for empty dir, got %v", err)
	}
}

func TestMarkdownCollectionReadFailure(t *testing.T) {
	t.Parallel()
	root := setupMockWorkspace(t, t.TempDir())
	docs, err := collectMarkdownDocsWithReader(root, func(path string) ([]byte, error) {
		if filepath.Base(path) == "setup.md" {
			return nil, os.ErrNotExist
		}
		return os.ReadFile(path)
	})
	if docs != nil || !errors.Is(err, os.ErrNotExist) || !strings.Contains(err.Error(), "setup.md") {
		t.Fatalf("docs=%v err=%v", docs, err)
	}
	_, err = processMarkdownFile(filepath.Join(root, "gone.md"), root, os.ReadFile)
	if !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("lost read error: %v", err)
	}
}

func TestIndexWorkspaceFailures(t *testing.T) {
	t.Parallel()
	for _, kind := range []string{"missing", "embedding", "save"} {
		t.Run(kind, func(t *testing.T) {
			t.Parallel()
			fixture := setupIndexFailure(t, kind)
			err := IndexWorkspaceMarkdown(context.Background(), fixture.store, fixture.root, fixture.embed)
			if err == nil || !strings.Contains(err.Error(), fixture.want) {
				t.Fatalf("want %s: %v", fixture.want, err)
			}
			if kind == "embedding" && !errors.Is(err, fixture.cause) {
				t.Fatalf("lost cause: %v", err)
			}
			assertCollectionNotSaved(t, kind, fixture.dbPath)
		})
	}
}

type indexFailureFixture struct {
	root, dbPath, want string
	store              *Store
	embed              chromem.EmbeddingFunc
	cause              error
}

func setupIndexFailure(t *testing.T, kind string) indexFailureFixture {
	t.Helper()
	root := setupMockWorkspace(t, t.TempDir())
	dbPath := filepath.Join(t.TempDir(), "vectors.db")
	store, err := NewStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	embed := chromem.EmbeddingFunc(noopEmbedder)
	cause := errors.New("offline embedding failure")
	want := "walk workspace"
	switch kind {
	case "missing":
		root = filepath.Join(root, "missing")
	case "embedding":
		want = "add documents"
		embed = func(context.Context, string) ([]float32, error) { return nil, cause }
	case "save":
		want = "save vector db"
		if err := os.Mkdir(dbPath, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	return indexFailureFixture{root: root, dbPath: dbPath, store: store, embed: embed, cause: cause, want: want}
}

func assertCollectionNotSaved(t *testing.T, kind, dbPath string) {
	t.Helper()
	if kind != "missing" {
		return
	}
	if _, err := os.Stat(dbPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("collection failure saved database: %v", err)
	}
}
