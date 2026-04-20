# Architecture Documentation

This document provides a deep dive into gobot's architecture, covering data flow, package responsibilities, and key design decisions.

## Data Flow Diagram

```
┌──────────────┐
│   Telegram   │  (User messages via BotFather)
└──────┬───────┘
       │
       ▼
┌──────────────┐
│  Bot Handler │  (Pairing gate, HITL checks, message normalization)
└──────┬───────┘
       │
       ▼
┌──────────────────────────┐
│  Agent Session Manager   │  (Session lifecycle, tool dispatch, compaction,
│                          │   memory window management, pruning)
└──────┬───────────────────┘
       │
       ▼
┌──────────────────────┐
│   LLM Provider       │  (Gemini / Claude / OpenAI abstraction)
│   (Factory Pattern)  │
└──────┬───────────────┘
       │
       ▼
┌────────────────────────────────────────────────┐
│              Tool Dispatch Loop                 │
│                                                 │
│  ┌──────────┐  ┌───────────┐  ┌──────────────┐ │
│  │  Spawn   │  │   Shell   │  │   Google     │ │
│  │  Tool    │  │   Tool    │  │   Tools      │ │
│  └──────────┘  └───────────┘  └──────────────┘ │
│                                                 │
│  ┌──────────┐  ┌───────────┐  ┌──────────────┐ │
│  │  Memory  │  │   Gmail   │  │   Search     │ │
│  │  Search  │  │   Tools   │  │   Web        │ │
│  └──────────┘  └───────────┘  └──────────────┘ │
└────────────────┬───────────────────────────────┘
                 │
                 ▼
┌────────────────────────────────┐
│   State / Memory / Cron        │
│                                 │
│  ┌──────────────────────────┐  │
│  │  Checkpoint Store        │  │  (SQLite: session state, iteration count)
│  │  (modernc.org/sqlite)    │  │
│  └──────────────────────────┘  │
│                                 │
│  ┌──────────────────────────┐  │
│  │  Long-Term Memory        │  │  (SQLite FTS5: semantic search index)
│  │  (memory.db)             │  │
│  └──────────────────────────┘  │
│                                 │
│  ┌──────────────────────────┐  │
│  │  Cron Scheduler          │  │  (Ephemeral sessions for recurring jobs)
│  │  (jobs.json + SQLite)    │  │
│  └──────────────────────────┘  │
└────────────────────────────────┘
```

## Package Responsibility Table

| Package | Path | Primary Responsibility | Key Files |
|---------|------|----------------------|-----------|
| `agent` | `internal/agent` | Core agent loop: LLM turns, tool dispatch, compaction, session management | `agent.go`, `compaction.go`, `handoff.go`, `hooks.go` |
| `audit` | `internal/audit` | Markdown audit report generation (immutable audit trail) | `audit.go`, `ledger.go`, `redact.go` |
| `bot` | `internal/bot` | Telegram bot client, message routing, pairing gate | `bot.go`, `pairing_handler.go` |
| `browser` | `internal/browser` | Pure-Go headless browser automation via chromedp | `browser.go`, `tools.go` |
| `config` | `internal/config` | Configuration loading from YAML/JSON, validation, typed accessors | `config.go`, `validator.go` |
| `context` | `internal/context` | Durable checkpointing and session state persistence (SQLite) | `manager.go`, `db.go`, `pairing.go` |
| `cron` | `internal/cron` | Autonomous background job scheduler | `scheduler.go`, `cron.go`, `batch.go` |
| `doctor` | `internal/doctor` | Pre-flight diagnostics and health checks | `doctor.go` |
| `gateway` | `internal/gateway` | HTTP gateway for external REST chat clients and future web dashboard | `gateway.go` |
| `google` | `internal/integrations/google` | Google Workspace integrations (Auth, Gmail, Calendar, Tasks) | `auth.go`, `gmail.go`, `calendar.go`, `tasks.go`, `search.go` |
| `infra` | `internal/infra` | Infrastructure wiring (DB init, lifecycle management) | `infra.go`, `resource_registry.go` |
| `memory` | `internal/memory` | SQLite-backed long-term memory with FTS5 search | `memory.go`, `sqlite_store.go`, `consolidator/` |
| `observability` | `internal/observability` | OpenTelemetry traces and metrics export | `otel.go`, `middleware.go` |
| `provider` | `internal/provider` | LLM provider abstraction (Gemini, Anthropic, OpenAI) | `factory.go` |
| `reflection` | `internal/reflection` | Pure-function reflection/planning loop utilities | `reflection.go` |
| `reporter` | `internal/reporter` | HTML report generation | `reporter.go` |
| `resilience` | `internal/resilience` | Circuit breakers, intelligent retry logic | `retry.go` |
| `sandbox` | `internal/sandbox` | Tool sandboxing and execution isolation | `executor_windows.go`, `executor_other.go` |
| `secrets` | `internal/secrets` | Encrypted secrets storage (cross-platform) | `secrets.go` |
| `shell` | `internal/shell` | Shell command execution tool | `redirect.go`, `clixml.go` |
| `state` | `internal/state` | Durable agent state with atomic writes and file locking | `manager.go` |
| `telegram` | `internal/telegram` | Telegram API client and formatting utilities | `telegram.go` |
| `testutil` | `internal/testutil` | Shared test helpers (table-driven test utilities) | `faulty_server.go` |
| `cmd/gobot` | `cmd/gobot` | Main binary entrypoint and CLI commands | `main.go`, `runner.go`, `tool_*.go` |

## Key Design Decisions

### 1. Pure Go (No CGO)

**Decision:** All dependencies use pure-Go implementations. Specifically, `modernc.org/sqlite` instead of `mattn/go-sqlite3`.

**Rationale:**
- Eliminates platform-specific build complexity (no C compiler required)
- Enables static linking for single-binary deployment
- Reduces attack surface (no CGO injection vulnerabilities)
- Simplifies CI/CD pipeline (no C library dependencies on build runners)

**Trade-offs:**
- `modernc.org/sqlite` is slower than `mattn/go-sqlite3` (pure-Go vs. native C)
- Slightly larger binary size compared to CGO-based builds

**Impact:** gobot compiles to a single binary that runs on any platform without external C dependencies.

---

### 2. WAL SQLite for Durability

**Decision:** All SQLite databases use WAL (Write-Ahead Logging) journal mode.

**Rationale:**
- WAL mode prevents database corruption on sudden power loss
- Enables concurrent reads during writes (readers don't block writers)
- Provides ACID guarantees for checkpoint persistence

**Implementation:**
- Checkpoint database (`gobot.db`) uses WAL mode
- Memory database (`memory.db`) uses WAL mode
- Atomic writes via `BEGIN IMMEDIATE` transactions

**Impact:** Sessions survive process crashes, and concurrent cron jobs can read checkpoint state without blocking.

---

### 3. Single-Writer Database Pattern

**Decision:** Only one goroutine writes to each SQLite database at a time.

**Rationale:**
- SQLite supports only one writer at a time (writer locks the database)
- Avoids `SQLITE_BUSY` errors from concurrent writes
- Simplifies error handling (no retry loops for lock contention)

**Implementation:**
- `internal/context/manager.go` serializes checkpoint writes via mutex
- `internal/memory/memory.go` serializes index writes via mutex
- Cron scheduler runs in its own goroutine but uses the same session manager

**Impact:** No database lock contention, but writes are serialized (acceptable for single-user workload).

---

### 4. Zero-Trust Security Model

**Decision:** Every inbound Telegram message must pass two gates before reaching the agent:
1. **Hard-whitelist:** The sender's chat ID must be in `channels.telegram.allowFrom`
2. **DB-backed pairing gate:** The chat ID must be authorized in the pairing store

**Rationale:**
- Prevents unauthorized use even if bot token is leaked
- Defense-in-depth: both config and database must allow the message
- Supports dynamic authorization/de-authorization at runtime

**Implementation:**
- `internal/bot/bot.go` implements `PairingHandler` that checks the pairing store
- Authorization is granted via `gobot authorize <pairing-code>` or direct chat ID
- HITL (Human-in-the-Loop) approval gate for sensitive tools (shell_exec, send_email)

**Impact:** Even with a leaked bot token, only explicitly authorized users can interact with the agent.

---

### 5. Strategic Hooks (F-012)

**Decision:** Custom logic is injected via `agent.Hooks` rather than modifying `internal/` core files.

**Rationale:**
- Prevents "core pollution" (one-off features scattered across core packages)
- Centralizes custom logic for easy auditing
- Enables toggling features without recompiling the agent

**Implementation:**
- `agent.Hooks` struct contains `PreDispatch`, `PostDispatch`, `PreTool`, `PostTool` hooks
- Hooks are registered at startup in `cmd/gobot/main.go` (e.g., `agent.NewHandoffHook`)
- Custom logic (PII redaction, output hardening) run through hooks

**Impact:** Custom logic (e.g., automated handoffs, PII redaction) is isolated from core agent logic.

---

### 6. Ephemeral Cron Sessions

**Decision:** Cron jobs use a fresh session manager with `nil` checkpoint store, so they never share history with user conversations.

**Rationale:**
- Cron jobs are independent tasks (e.g., "morning briefing", "calendar check")
- Sharing checkpoint history would pollute user sessions with cron-generated content
- Simplifies rollback (delete cron job, no checkpoint pollution)

**Implementation:**
- `cronDispatcher` creates a new `SessionManager` with `store=nil` in `cmd/gobot/main.go`
- Cron jobs run in isolation, no checkpoint saved to disk

**Impact:** Cron jobs can't accidentally corrupt user sessions, and user sessions don't contain cron-generated noise.

---

### 7. Secret Encryption (Cross-Platform)

**Decision:** OAuth2 tokens and API keys are encrypted at rest using platform-appropriate mechanisms:
- **Windows:** DPAPI (`CryptProtectData` / `CryptUnprotectData`) — user-scoped, OS-managed keys
- **Linux/macOS:** AES-256-GCM with a 32-byte random key persisted at `~/.config/gobot/encryption.key` (mode 0600)

**Rationale:**
- DPAPI ties encryption to the current Windows user account; no separate key management needed
- AES-256-GCM provides strong authenticated encryption on non-Windows; the key file is isolated from the encrypted data directory
- Both approaches prevent casual reading of token files by other OS users
- Set `GOBOT_ENCRYPTION_KEY_FILE` to override the key path (useful for CI/containers)

**Implementation:**
- `internal/secrets/dpapi_windows.go` — Windows DPAPI via `golang.org/x/sys/windows`
- `internal/secrets/dpapi_stub.go` — Linux/macOS AES-256-GCM (standard library only, no CGO)
- `internal/secrets/secrets.go` — platform-agnostic `SecretsStore` wrapping both

**Limitation:** On Linux/macOS, the key file at `~/.config/gobot/encryption.key` protects tokens within the same user account but is not tied to login credentials the way DPAPI is. Protect this file with OS-level permissions (0600 is enforced on creation).

**Impact:** Token files are unusable without the corresponding key file; cross-platform support is maintained without CGO.

---

### 8. OpenTelemetry Observability

**Decision:** All agent dispatches are traced via OpenTelemetry SDK, with metrics exported to OTLP endpoints.

**Rationale:**
- Distributed traces help debug multi-turn agent failures
- Metrics (latency, token usage, tool success/failure) enable capacity planning
- Standard protocol (OTLP) integrates with any observability backend

**Implementation:**
- `internal/observability/otel.go` initializes the OTLP provider
- `DispatchTracer` wraps each agent turn in a span with attributes (session ID, model, iteration)
- Metrics are exported on a 15-second interval via `otel/sdk/metric`

**Impact:** Operators can monitor agent performance via dashboards (Grafana, Jaeger, etc.) and detect regressions.

---

## Future Architecture Considerations

### Multi-User Workspace Isolation (F-073)

Currently, gobot assumes a single user per instance. The architecture supports multi-user isolation via:
- Separate SQLite database connections per user (with connection pooling)
- Namespace partitioning in the memory index (user-specific FTS5 tables)
- Per-user session directories under `Gobot_Storage/sessions/{user_id}/`

This will be implemented when the project scales beyond single-user deployments.

---

*Last updated: 2026-04-19*
