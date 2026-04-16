package vector_test

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/allthingscode/gobot/internal/memory/vector"
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
	store, err := vector.NewStore(dbPath)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}

	var embedFunc chromem.EmbeddingFunc = noopEmbedder

	if err := vector.IndexWorkspaceMarkdown(ctx, store, wsDir, embedFunc); err != nil {
		t.Fatalf("IndexWorkspaceMarkdown: %v", err)
	}

	verifyIndexedContent(t, ctx, store, embedFunc)
}

func setupMockWorkspace(t *testing.T, tempDir string) string {
	t.Helper()
	wsDir := filepath.Join(tempDir, "workspace")
	files := map[string]string{
		"README.md":            "# Readme\nContent here.",
		"docs/setup.md":       "# Setup\nStep 1.",
		"vendor/dep.md":       "should skip",
		".private/secret.md": "should skip",
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

func verifyIndexedContent(t *testing.T, ctx context.Context, store *vector.Store, embedFunc chromem.EmbeddingFunc) {
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
	store, _ := vector.NewStore(dbPath)

	if err := vector.IndexWorkspaceMarkdown(ctx, store, wsDir, noopEmbedder); err != nil {
		t.Errorf("expected no error for empty dir, got %v", err)
	}
}
