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
| `agent` | `internal/agent` | Core agent loop: LLM turns, tool dispatch, compaction, session management | `agent.go`, `agent_test.go` |
| `audit` | `internal/audit` | Markdown audit report generation (immutable audit trail) | `audit.go`, `audit_test.go` |
| `bot` | `internal/bot` | Telegram bot client, message routing, pairing gate | `bot.go`, `bot_test.go` |
| `config` | `internal/config` | Configuration loading from YAML/JSON, validation, typed accessors | `config.go`, `config_test.go` |
| `context` | `internal/context` | Durable checkpointing and session state persistence (SQLite) | `manager.go`, `manager_test.go` |
| `cron` | `internal/cron` | Autonomous background job scheduler | `scheduler.go`, `scheduler_test.go` |
| `doctor` | `internal/doctor` | Pre-flight diagnostics and health checks | `doctor.go`, `doctor_test.go` |
| `gateway` | `internal/gateway` | HTTP gateway for Telegram webhook and future web dashboard | `gateway.go`, `gateway_test.go` |
| `gmail` | `internal/gmail` | Gmail search and read tools | `gmail.go`, `gmail_test.go` |
| `google` | `internal/google` | Google OAuth2 + Calendar/Tasks API clients | `auth.go`, `auth_test.go` |
| `infra` | `internal/infra` | Infrastructure wiring (DB init, lifecycle management) | `infra.go`, `infra_test.go` |
| `memory` | `internal/memory` | SQLite-backed long-term memory with FTS5 search | `memory.go`, `memory_test.go` |
| `observability` | `internal/observability` | OpenTelemetry traces and metrics export | `otel.go`, `otel_test.go` |
| `provider` | `internal/provider` | LLM provider abstraction (Gemini, Anthropic, OpenAI) | `factory.go`, `provider_test.go` |
| `reflection` | `internal/reflection` | Pure-function reflection/planning loop utilities | `reflection.go`, `reflection_test.go` |
| `reporter` | `internal/reporter` | HTML report generation | `reporter.go`, `reporter_test.go` |
| `resilience` | `internal/resilience` | Circuit breakers, intelligent retry logic | `retry.go`, `retry_test.go` |
| `sandbox` | `internal/sandbox` | Tool sandboxing and execution isolation | `executor_windows.go`, `executor_test.go` |
| `secrets` | `internal/secrets` | DPAPI-encrypted secrets storage (Windows) | `secrets.go`, `secrets_test.go` |
| `shell` | `internal/shell` | Shell command execution tool | `redirect.go`, `shell_test.go` |
| `state` | `internal/state` | Durable agent state with atomic writes and file locking | `manager.go`, `manager_test.go` |
| `strategic` | `internal/strategic` | Strategic hooks (F-012) for custom logic injection | `mandate.go`, `strategic_test.go` |
| `telegram` | `internal/telegram` | Telegram API client and formatting utilities | `telegram.go`, `telegram_test.go` |
| `testutil` | `internal/testutil` | Shared test helpers (table-driven test utilities) | `faulty_server.go` |
| `cmd/gobot` | `cmd/gobot` | Main binary entrypoint and CLI commands | `main.go`, `runner_test.go` |

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

**Decision:** Custom logic is injected via `internal/strategic` hooks rather than modifying `internal/` core files.

**Rationale:**
- Prevents "core pollution" (one-off features scattered across core packages)
- Centralizes custom logic for easy auditing
- Enables toggling features without recompiling the agent

**Implementation:**
- `agent.Hooks` struct contains `PreDispatch`, `PostDispatch`, `PreTool`, `PostTool` hooks
- Hooks are registered at startup in `cmd/gobot/main.go` (e.g., `agent.NewHandoffHook`)
- Strategic mandates (PII redaction, output hardening) run through hooks

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

### 7. DPAPI Secret Encryption (Windows)

**Decision:** On Windows, OAuth2 tokens and API keys are encrypted via DPAPI (`CryptProtectData` / `CryptUnprotectData`).

**Rationale:**
- DPAPI ties encryption to the current user account (tokens are unreadable by other users)
- No need to manage separate encryption keys (Windows handles key management)
- Compliance with enterprise security standards

**Implementation:**
- `internal/secrets/secrets.go` wraps Windows DPAPI calls via `golang.org/x/sys/windows`
- On Linux/macOS, a fallback file-based encryption is used (less secure than DPAPI)

**Impact:** Stolen token files are unusable on different machines or user accounts (Windows only).

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

*Last updated: 2026-04-05*
