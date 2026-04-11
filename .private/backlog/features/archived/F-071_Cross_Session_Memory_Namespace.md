---
item_id: "F-071"
type: "Feature"
status: "Resolved"
target_specialist: "Architect"
priority: "P3"
created_at: "2026-04-04"
updated_at: "2026-04-10"
---

# Specification: Cross-Session Shared Memory Namespace

## Agent Directive
As an autonomous agent, read this file carefully. Do not begin implementation until you have analyzed the `Context Files` below, formulated a plan, and received approval. Follow all Go-native mandates strictly.

## Overview
- **Objective:** Allow certain facts to persist and be retrievable across all sessions, not just within the session that originally learned them.
- **Problem Statement:** All FTS5 memory entries are indexed under `session_key`, making them invisible to every other session. Facts like user preferences ("always use metric units"), standing project state ("Project Alpha deadline is May 1"), and recurring instructions are re-learned from scratch in every new conversation. This wastes consolidation calls and produces inconsistent agent behavior across sessions.

## Context Files
- `C:\Users\HayesChiefOfStaff\Documents\gobot\CLAUDE.md` (global constraints)
- `C:\Users\HayesChiefOfStaff\Documents\gobot\internal\memory\sqlite_store.go` (MemoryStore — FTS5 schema and CRUD)
- `C:\Users\HayesChiefOfStaff\Documents\gobot\internal\memory\consolidator\consolidator.go` (fact extraction and indexing)
- `C:\Users\HayesChiefOfStaff\Documents\gobot\cmd\gobot\tool_memory.go` (search_memory tool)
- `C:\Users\HayesChiefOfStaff\Documents\gobot\internal\config\config.go` (config structs)

## Architectural Design

### Namespace model
Introduce a `namespace` concept alongside `session_key` in the FTS5 store:

- `session:{session_key}` — current behavior; facts visible only within the originating session.
- `global` — facts visible to all sessions; written when the consolidator identifies globally relevant information (preferences, standing facts, project-wide state).

The `session_key` column in `memory_fts` is renamed `namespace`. Functionally equivalent for existing session-scoped entries (values become `session:{key}`). The schema migration runs at store open time via `PRAGMA user_version`.

### Write path
`MemoryStore.Index` gains a `namespace string` parameter. Callers pass `"session:"+sessionKey` for normal session facts and `"global"` for cross-session facts.

The consolidator receives a new `GlobalNamespacePatterns []string` config field — a list of keyword patterns that, when matched against an extracted fact, cause it to be written to the global namespace. Example patterns: `"prefer", "always", "never", "deadline", "reminder"`. If no patterns are configured, all facts remain session-scoped (safe default — no behavior change without opt-in config).

### Read path
`MemoryStore.Search` queries both the caller's session namespace AND `global` in a single FTS5 query using `namespace IN ('session:{key}', 'global')`. Results are merged and deduplicated by content before returning.

`search_memory` tool passes the current session key to the store; it needs no changes beyond the updated `Search` signature.

### TTL cleanup
`CleanupExpired` applies independently per namespace. Global facts use the `compaction.memoryFlush.globalTTL` config field (default: no expiry — global facts are long-lived by design). Session facts continue using `compaction.memoryFlush.ttl`.

### Config additions
```json
"compaction": {
  "memoryFlush": {
    "ttl": "2160h",
    "globalTTL": "",
    "globalNamespacePatterns": ["prefer", "always", "never", "deadline", "reminder", "going forward"]
  }
}
```

## State Management / Rollback Plan
Schema migration is additive (rename column via `ALTER TABLE ... RENAME COLUMN`, or recreate table). Run migration at store open time, gated by `PRAGMA user_version`. If migration fails, log and fall back to session-only mode. Existing data is preserved; no entries are deleted during migration.

`git checkout internal/memory/sqlite_store.go internal/memory/consolidator/consolidator.go cmd/gobot/tool_memory.go` to revert if needed.

## Constraints & Mandates
- **No CGO:** `modernc.org/sqlite` only.
- **Backward compatible default:** If `globalNamespacePatterns` is empty, all facts are session-scoped. Zero behavior change on existing configs.
- **No breaking API changes** to `MemoryStore` until the migration path is solid.
- **Schema migration must be idempotent** — safe to run on a store that is already migrated.

## Hard Mandates (Verification)
- [ ] `-mod=readonly` for all commands
- [ ] Table-driven tests with 80%+ coverage on namespace routing and search merge logic
- [ ] No external API calls in unit tests

## Implementation Steps
1. Read `sqlite_store.go` in full. Understand current FTS5 schema and all callers of `Index` and `Search`.
2. Design migration: add `namespace` column (FTS5 `UNINDEXED`), backfill existing rows with `'session:' || old_session_key` value, bump `PRAGMA user_version`.
3. Update `MemoryStore.Index(namespace, content string) error` signature.
4. Update `MemoryStore.Search(query, sessionKey string, limit int)` to query `namespace IN ('session:{sessionKey}', 'global')`.
5. Update `MemoryStore.CleanupExpired` to accept per-namespace TTL.
6. Update consolidator: read `GlobalNamespacePatterns` from config; after fact extraction, route each fact to `global` if any pattern matches, else `session:{key}`.
7. Update `tool_memory.go` to pass `sessionKey` to `Search` (may already be passed — verify).
8. Write table-driven tests:
   - Fact indexed as global is returned by a different session's search
   - Fact indexed as session-scoped is NOT returned by a different session's search
   - Pattern matching routes correctly to global vs session namespaces
   - Migration: existing store with old schema is correctly upgraded and all existing facts are accessible
   - `CleanupExpired` with global TTL empty leaves global entries untouched

## Verification Command
```powershell
go test -mod=readonly ./internal/memory/... ./cmd/gobot/... -cover
```

## Acceptance Criteria
- [ ] `MemoryStore` schema includes a `namespace` column; migration from prior schema is idempotent
- [ ] Facts matching `globalNamespacePatterns` are indexed under `"global"` namespace
- [ ] `Search` returns results from both `global` and caller's session namespace in a single query
- [ ] Facts from session A are not returned by a search from session B (session isolation preserved)
- [ ] Facts from `global` namespace are returned by searches from any session
- [ ] `CleanupExpired` respects per-namespace TTL settings; global entries are not pruned when `globalTTL` is empty
- [ ] Default config (no `globalNamespacePatterns`) produces identical behavior to current implementation
- [ ] All existing `sqlite_store` and `tool_memory` tests pass

## Related Items
- **F-030 (Vector/Semantic Memory):** When the hybrid store is implemented, the namespace model defined here should extend to the vector store as well. Coordinate to avoid divergent namespace schemes.
- **F-025 (Local RAG):** Workspace document indexing is inherently global (not session-scoped). F-025 should use the `global` namespace when it lands.
