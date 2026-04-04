# Research: Go-Based OpenClaw Competitor Landscape

**Date:** 2026-04-04
**Purpose:** Comparative analysis of Go-based projects in the OpenClaw/Clawd ecosystem to inform GoBot's architectural decisions.

---

## Projects Examined

### Official Reference
| Project | OpenClaw (openclaw/openclaw) |
|---------|------------------------------|
| **Language** | TypeScript (NOT Go) |
| **Stars** | 347k+ |
| **Key Takeaway** | Canonical project, 37+ channels, 10+ providers, but TypeScript. All Go projects are reimplementations or inspirations. |

### Go Reimplementations

| Project | Stars | Architecture | Channels | Memory | Notable |
|---------|-------|--------------|----------|--------|---------|
| **GoClaw** (nextlevelbuilder) | 1.5k | Multi-tenant, PostgreSQL + pgvector | 7 (Telegram, Discord, Slack, etc.) | pgvector + BM25 hybrid | Agent teams, inter-agent delegation, 20+ providers |
| **Memoh** | 1.3k | Containerized (containerd), per-bot isolation | 9 (Telegram, Discord, Matrix, etc.) | Pluggable: Mem0/Qdrant, dense+sparse+BM25 | Multi-user with ACL, graphical config UI |
| **FastClaw** | 464 | Plugin system (JSON-RPC over stdin/stdout) | Web + plugins (Telegram, Discord, Slack) | MEMORY.md + searchable logs | Before/after hook system, policy engine |
| **Clawlet** | 632 | Static binary, no CGO, sqlite-vec | CLI only | sqlite-vec hybrid | Ultra-lightweight |
| **maxclaw** | 200 | Go backend + Electron desktop | Telegram, WhatsApp bridge, Discord, WebSocket | MEMORY.md layering + daily digest | Desktop-first, one-command install |
| **LiteClaw** | 57 | Single binary, ~10MB RAM | Telegram, Discord, iMessage, Slack (experimental) | Persistent notes + context retention | Minimalist, many providers (10+) |
| **GoGogot** | 115 | Simple `for` loop agent, ~5.5k lines | Telegram only | soul.md/MD notes, auto-evolving identity | Context compaction near token limits |

---

## How GoBot Compares (As of April 2026)

### Where GoBot Leads

| Capability | GoBot Status | Competitor Gap |
|------------|--------------|----------------|
| Google Workspace (Calendar, Tasks, Gmail) | Deep integration | None of the competitors have this |
| HITL approval framework | Implemented | Only basic "ask" modes in maxclaw/GoClaw |
| OpenTelemetry tracing | Implemented | Only GoClaw (nextlevelbuilder) has similar |
| Checkpoint/resume (SQLite) | Implemented | Most use in-memory or simple file-based |
| Memory consolidation/compaction | Implemented | Only Memoh has comparable compaction |
| Circuit breakers | Implemented (gobreaker) | Rare in this space |
| DM pairing | Implemented | Only maxclaw and LiteClaw have similar |
| Multi-provider (Gemini/Anthropic/OpenAI) | Implemented | GoClaw has 20+, most have 3-6 |
| Per-specialist model routing | Implemented | Rare |

### Where GoBot Lags

| Capability | GoBot Status | Competitor Approach | Verdict |
|------------|--------------|---------------------|---------|
| Idempotency keys | Not implemented | OpenClaw wire protocol standard | Worth adding (→ F-069) |
| Context summarization | TTL pruning only | GoGogot/Clawlet compress old turns | Worth adding (→ F-070) |
| Web dashboard | API-only gateway | FastClaw/Memoh/maxclaw all have UIs | Worth adding (→ F-072) |
| Hybrid memory search | FTS5 keyword only | GoClaw (pgvector+BM25), Memoh (dense+sparse+BM25) | Worth adding (→ F-025/F-030) |
| Multi-user isolation | Single-user | GoClaw (multi-tenant), Memoh (containerized) | Maybe later (→ F-073) |
| SKILL.md / plugin system | Hardcoded tools | FastClaw (JSON-RPC plugins), LiteClaw (SKILL.md) | **Rejected** — contradicts stability-first philosophy |
| MCP support | Not wanted | Many competitors support MCP as first-class transport | **Explicitly rejected** |

---

## Design Patterns Worth Capturing

### 1. Hybrid Retrieval (FTS5 + Vector + RRF) — Adopted
Most successful Go projects combine keyword and semantic search. GoClaw uses pgvector+BM25, Memoh uses dense+sparse+BM25. GoBot's existing FTS5 BM25 is a solid foundation — adding `chromem-go` for vector search with Reciprocal Rank Fusion gives comparable quality without a separate database dependency.

### 2. Idempotency Keys — Adopted
OpenClaw's wire protocol requires idempotency keys for side-effecting methods. This prevents duplicate emails, calendar entries, etc. from agent loop retries. Simple, proven pattern.

### 3. Context Summarization — Adopted
Simple projects like GoGogot do aggressive context compaction near token limits. GoBot's current approach (TTL pruning + KeepLastAssistants) loses information by dropping turns entirely. Summarizing old turns preserves key decisions and facts in condensed form.

### 4. Memory Compaction with LLM Fact Extraction — Already Done
Memoh and maxclaw both extract facts from conversation history into persistent notes during "compaction" cycles. GoBot already has this via the memory consolidator and F-068 (Memory-Flush Compaction Strategy).

### 5. Heartbeat with Context — Already Done
maxclaw's `memory/heartbeat.md` pattern matches GoBot's 15-minute heartbeat with alerting.

### 6. Simple Server-Rendered Dashboard — Adopted (with caveats)
FastClaw, Memoh, and maxclaw all have web UIs. GoBot's HTTP gateway provides the foundation. Best approach is server-rendered Go templates with light HTMX/Alpine.js — no React/Vue build steps, consistent with stability-first philosophy.

---

## Philosophy Note

GoBot's North Star is **stability over extensibility**. Competitor projects with the highest star counts (GoClaw at 1.5k, Memoh at 1.3k) are impressive but complex — multi-tenant databases, container orchestration, plugin ecosystems. GoBot prioritizes:

1. Rock-solid single-user operation
2. Deep integration with Matthew's existing tooling (Telegram, Google Workspace)
3. Minimal dependency surface (pure Go, no CGO)
4. Features that improve reliability over features that expand capability
5. MCP is explicitly rejected

This means GoBot will likely never match competitor feature counts — and that's intentional. The goal is an assistant that never lets you down, not one that can do everything.
