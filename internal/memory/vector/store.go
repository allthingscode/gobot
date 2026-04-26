package vector

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sync"

	"github.com/philippgille/chromem-go"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"
)

// Store wraps chromem.DB to manage the vector database lifecycle.
type Store struct {
	db     *chromem.DB
	dbPath string
	mu     sync.RWMutex
}

// NewStore creates or loads a vector DB from the given path.
func NewStore(dbPath string) (*Store, error) {
	if err := os.MkdirAll(filepath.Dir(dbPath), 0o755); err != nil {
		return nil, fmt.Errorf("create vector db dir: %w", err)
	}

	db := chromem.NewDB()
	store := &Store{
		db:     db,
		dbPath: dbPath,
	}

	if _, err := os.Stat(dbPath); err == nil {
		if err := db.ImportFromFile(dbPath, ""); err != nil {
			return nil, fmt.Errorf("import vector db: %w", err)
		}
	}
	return store, nil
}

// Save persists the database to disk using gob encoding and gzip compression.
func (s *Store) Save() error {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if err := s.db.ExportToFile(s.dbPath, true, ""); err != nil {
		return fmt.Errorf("export vector db: %w", err)
	}
	return nil
}

// AddDocuments adds multiple documents to a collection concurrently.
func (s *Store) AddDocuments(ctx context.Context, collectionName string, docs []chromem.Document, embeddingFunc chromem.EmbeddingFunc) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	col, err := s.db.GetOrCreateCollection(collectionName, nil, embeddingFunc)
	if err != nil {
		return fmt.Errorf("get or create collection: %w", err)
	}

	// 4 is a reasonable concurrency default for local embedding requests
	if err := col.AddDocuments(ctx, docs, 4); err != nil {
		return fmt.Errorf("add documents: %w", err)
	}

	return nil
}

// AddDocument adds a single document to a collection.
func (s *Store) AddDocument(ctx context.Context, collectionName string, doc chromem.Document, embeddingFunc chromem.EmbeddingFunc) error {
	return s.AddDocuments(ctx, collectionName, []chromem.Document{doc}, embeddingFunc)
}

// Search performs a cosine similarity search on the collection with optional metadata filtering.
func (s *Store) Search(ctx context.Context, collectionName, query string, limit int, where map[string]string, embeddingFunc chromem.EmbeddingFunc) ([]chromem.Result, error) {
	ctx, span := otel.Tracer("gobot-memory").Start(ctx, "vector.Store.Search",
		trace.WithAttributes(
			attribute.String("memory.collection", collectionName),
			attribute.Int("memory.limit", limit),
		),
	)
	defer span.End()

	s.mu.RLock()
	defer s.mu.RUnlock()

	col := s.db.GetCollection(collectionName, embeddingFunc)
	if col == nil {
		return nil, nil // Collection does not exist yet
	}

	// chromem-go requires nResults <= count
	count := col.Count()
	if limit > count {
		limit = count
	}
	if limit <= 0 {
		return nil, nil
	}

	results, err := col.Query(ctx, query, limit, where, nil)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
		return nil, fmt.Errorf("query collection: %w", err)
	}

	span.SetAttributes(attribute.Int("memory.results_count", len(results)))
	return results, nil
}

// Close is a no-op for the in-memory db, but provided for interface consistency.
func (s *Store) Close() error {
	return nil
}
