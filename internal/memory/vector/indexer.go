package vector

import (
	"context"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/philippgille/chromem-go"
)

// IndexWorkspaceMarkdown scans the workspace directory for .md files, chunks them,
// and indexes them into the given store under the "workspace_docs" collection.
func IndexWorkspaceMarkdown(ctx context.Context, store *Store, workspaceDir string, embeddingFunc chromem.EmbeddingFunc) error {
	allDocs, err := collectMarkdownDocs(workspaceDir)
	if err != nil {
		return err
	}

	if len(allDocs) > 0 {
		if err := store.AddDocuments(ctx, "workspace_docs", allDocs, embeddingFunc); err != nil {
			return fmt.Errorf("add documents to store: %w", err)
		}
		if err := store.Save(); err != nil {
			return fmt.Errorf("save vector db: %w", err)
		}
		slog.Info("vector indexer: successfully indexed markdown files", "chunks", len(allDocs))
	}

	return nil
}

func collectMarkdownDocs(workspaceDir string) ([]chromem.Document, error) {
	var allDocs []chromem.Document
	err := filepath.WalkDir(workspaceDir, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if shouldSkip(d) {
			return fs.SkipDir
		}
		if !strings.HasSuffix(path, ".md") || d.IsDir() {
			return nil
		}

		docs := processMarkdownFile(path, workspaceDir)
		allDocs = append(allDocs, docs...)
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("walk workspace dir: %w", err)
	}
	return allDocs, nil
}

func shouldSkip(d fs.DirEntry) bool {
	if !d.IsDir() {
		return false
	}
	name := d.Name()
	return strings.HasPrefix(name, ".") || name == "vendor" || name == "node_modules"
}

func processMarkdownFile(path, workspaceDir string) []chromem.Document {
	data, err := os.ReadFile(path)
	if err != nil {
		slog.Warn("vector indexer: unreadable file", "path", path, "err", err)
		return nil
	}

	rel, err := filepath.Rel(workspaceDir, path)
	if err != nil {
		rel = filepath.Base(path)
	}

	chunks := chunkMarkdown(string(data), 1000)
	docs := make([]chromem.Document, 0, len(chunks))
	for i, chunk := range chunks {
		docs = append(docs, chromem.Document{
			ID:      fmt.Sprintf("%s#chunk-%d", rel, i),
			Content: chunk,
			Metadata: map[string]string{
				"source":    rel,
				"timestamp": time.Now().UTC().Format(time.RFC3339),
			},
		})
	}
	return docs
}

// chunkMarkdown splits markdown text into paragraph-level chunks of ~targetSize characters.
func chunkMarkdown(text string, targetSize int) []string {
	paragraphs := strings.Split(text, "\n\n")
	var chunks []string
	var currentChunk strings.Builder

	// Track the last paragraph to provide overlap
	var lastParagraph string

	for _, p := range paragraphs {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}

		// If adding this paragraph exceeds target (and chunk is not empty)
		if currentChunk.Len() > 0 && currentChunk.Len()+len(p) > targetSize {
			chunks = append(chunks, strings.TrimSpace(currentChunk.String()))
			currentChunk.Reset()

			// Overlap: start new chunk with the last paragraph
			if lastParagraph != "" {
				currentChunk.WriteString(lastParagraph)
				currentChunk.WriteString("\n\n")
			}
		}

		currentChunk.WriteString(p)
		currentChunk.WriteString("\n\n")
		lastParagraph = p
	}

	if currentChunk.Len() > 0 {
		chunks = append(chunks, strings.TrimSpace(currentChunk.String()))
	}

	return chunks
}
