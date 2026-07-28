//nolint:testpackage // covers package-private search_docs helpers
package app

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/memory/vector"
)

func TestSearchDocsToolExecuteRequiresQuery(t *testing.T) {
	t.Parallel()

	tool := newSearchDocsTool(nil, nil, nil, nil)
	_, err := tool.Execute(context.Background(), "session", "user", map[string]any{})
	if err == nil {
		t.Fatal("expected missing query error")
	}
	if !strings.Contains(err.Error(), "query is required") {
		t.Fatalf("expected query validation error, got %v", err)
	}
}

func TestSearchDocsSearchFTSMapsRowsAndDoublesLimit(t *testing.T) {
	t.Parallel()

	mem := &mockMemoryStore{
		results: []map[string]any{
			{"namespace": "doc:a", "content": "alpha", "timestamp": "2026-07-28T00:00:00Z"},
			{"namespace": 123, "content": nil, "timestamp": "ignored types"},
		},
	}
	tool := newSearchDocsTool(mem, nil, nil, nil)

	got, err := tool.searchFTS(context.Background(), "alpha", 3)
	if err != nil {
		t.Fatalf("searchFTS: %v", err)
	}
	if mem.lastQuery != "alpha" || mem.lastSessionKey != "" || mem.lastLimit != 6 {
		t.Fatalf("Search called with query=%q session=%q limit=%d", mem.lastQuery, mem.lastSessionKey, mem.lastLimit)
	}
	if len(got) != 2 {
		t.Fatalf("mapped result count = %d, want 2", len(got))
	}
	assertFTSResult(t, got[0], "doc:a", "alpha", "2026-07-28T00:00:00Z")
	assertFTSResult(t, got[1], "", "", "ignored types")
}

func assertFTSResult(t *testing.T, got vector.FTSResult, wantID, wantContent, wantTimestamp string) {
	t.Helper()

	if got.ID != wantID || got.Content != wantContent || got.Timestamp != wantTimestamp {
		t.Fatalf("mapped result = %+v, want ID=%q Content=%q Timestamp=%q", got, wantID, wantContent, wantTimestamp)
	}
}

func TestSearchDocsSearchFTSWrapsStoreError(t *testing.T) {
	t.Parallel()

	tool := newSearchDocsTool(&mockMemoryStore{err: errors.New("store unavailable")}, nil, nil, nil)
	_, err := tool.searchFTS(context.Background(), "alpha", 1)
	if err == nil {
		t.Fatal("expected store error")
	}
	if !strings.Contains(err.Error(), "fts search: store unavailable") {
		t.Fatalf("expected wrapped FTS error, got %v", err)
	}
}
