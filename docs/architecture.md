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
│  Bot Handler │  (bot: allow-list/pairing gate and routing; app: TgAPI transport)
└──────┬───────┘
       │
       ▼
┌──────────────────────────┐
│  Agent Session Manager   │  (agent: session lifecycle, compaction, hooks;
│                          │   app DispatchHandler glues bot, agent and memory)
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
│       Tool Dispatch Loop (app.AgentRunner)      │
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
│  │  Long-Term Memory        │  │  (SQLite FTS5: lexical search index)
│  │  (memory.db)             │  │
│  └──────────────────────────┘  │
│  ┌ - - - - - - - - - - - - -┐  │
│  │  Vector Store (optional) │  │  (embedding retrieval; falls back to FTS5)
│  └ - - - - - - - - - - - - -┘  │
│                                 │
│  ┌──────────────────────────┐  │
│  │  Cron Scheduler          │  │  (cron: scheduling; app: dispatch, ephemeral
│  │  (jobs.json + SQLite)    │  │   sessions for recurring jobs)
│  └──────────────────────────┘  │
└────────────────────────────────┘
```

## Package Responsibility Table

| Package | Path | Primary Responsibility | Key Files |
|---------|------|----------------------|-----------|
| `app` | `internal/app` | Composition layer behind `gobot run`: wiring, startup/shutdown, `AgentRunner` LLM/tool loop and tool execution, `DispatchHandler`, `TgAPI` telego transport, cron channel dispatch | `app.go`, `bootstrap.go`, `app_setup.go`, `app_servers.go`, `runner.go`, `runner_tools.go`, `handler.go`, `telegram.go`, `cron.go` |
| `agent` | `internal/agent` | Contracts and session management: `Runner` interface, `SessionManager`, compaction, hooks, policy and HITL | `agent.go`, `session_history.go`, `compaction.go`, `hooks.go`, `policy.go`, `hitl.go` |
| `audit` | `internal/audit` | Markdown audit report generation (immutable audit trail) | `audit.go`, `ledger.go`, `redact.go` |
| `bot` | `internal/bot` | Transport-agnostic polling runtime: `API` and `Handler` interfaces, message routing, pairing gate (no Telegram SDK) | `bot.go`, `pairing_handler.go` |
| `browser` | `internal/browser` | Pure-Go headless browser automation via chromedp | `browser.go`, `tools.go` |
| `config` | `internal/config` | Configuration loading from JSON, validation, typed accessors | `config.go`, `validator.go` |
| `context` | `internal/context` | Durable checkpointing and session state persistence (SQLite) | `manager.go`, `db.go`, `pairing.go` |
| `cron` | `internal/cron` | Job scheduling and reconciliation; hands due jobs to a `Dispatcher` (implemented by `app.CronDispatcher`) | `scheduler.go`, `cron.go`, `batch.go` |
| `doctor` | `internal/doctor` | Pre-flight diagnostics and health checks | `doctor.go` |
| `gateway` | `internal/gateway` | HTTP gateway for external REST chat clients and future web dashboard | `gateway.go` |
| `google` | `internal/integrations/google` | Google Workspace integrations (Auth, Gmail, Calendar, Tasks) | `auth.go`, `gmail.go`, `calendar.go`, `tasks.go`, `search.go` |
| `infra` | `internal/infra` | Filesystem helpers (media path resolution, directory listing, log reading) | `infra.go` |
| `memory` | `internal/memory` | SQLite-backed long-term memory with FTS5 lexical search; optional vector retrieval in `vector/`; async fact extraction in `consolidator/` | `memory.go`, `sqlite_store.go`, `vector/hybrid.go`, `vector/store.go`, `consolidator/consolidator.go` |
| `observability` | `internal/observability` | OpenTelemetry traces and metrics export | `otel.go`, `middleware.go` |
| `provider` | `internal/provider` | LLM provider abstraction (Gemini, Anthropic, OpenAI) | `factory.go` |
| `reflection` | `internal/reflection` | Pure-function reflection/planning loop utilities | `reflection.go` |
| `reporter` | `internal/reporter` | HTML report generation | `reporter.go` |
| `resilience` | `internal/resilience` | Circuit breakers, intelligent retry logic | `retry.go` |
| `sandbox` | `internal/sandbox` | Tool sandboxing and execution isolation | `executor_windows.go`, `executor_other.go` |
| `secrets` | `internal/secrets` | Encrypted secrets storage (cross-platform) | `secrets.go` |
| `shell` | `internal/shell` | Shell command execution tool | `redirect.go`, `clixml.go` |
| `state` | `internal/state` | Durable agent state with atomic writes and file locking | `manager.go` |
| `telegram` | `internal/telegram` | Pure Markdown-to-Telegram-HTML formatting (no client; the client is `app.TgAPI`) | `formatter.go` |
| `testutil` | `internal/testutil` | Shared test helpers (table-driven test utilities) | `faulty_server.go` |
| `cmd/gobot` | `cmd/gobot` | Main binary entrypoint and CLI commands; `cmdRun` calls `app.RunAgent` | `main.go`, `cli_*.go` |

## Source Navigator

Entry points per flow. Each row is a starting point, not a universal call stack; branches marked "if" depend on configuration.

| Flow | Where to start | Notes |
|------|----------------|-------|
| Startup | `cmd/gobot/main.go` `cmdRun` -> `internal/app/app.go` `RunAgent` -> `BuildAgentStack` (`bootstrap.go`) -> `runInitializedAgentLoop` | `app_setup.go` (`SetupHooks`, `SetupConsolidator`, `SetupGateHandler`) and `app_servers.go` (gateway, dashboard, `StartTelegramBot`, `StartCron`, `StartHeartbeat`) start subsystems; each is conditional on config. |
| Incoming message and reply | `internal/app/telegram.go` `TgAPI.Updates` -> `internal/bot/bot.go` `Bot` -> `bot.NewPairingHandler` (`pairing_handler.go`) -> `app.DispatchHandler.Handle` (`handler.go`) -> `agent.SessionManager.Dispatch` (`agent.go`) -> `app.AgentRunner.Run` (`runner.go`) | `bot` depends only on the `API` and `Handler` interfaces; `TgAPI.Send` delivers the reply and `internal/telegram/formatter.go` `ToHTML` formats it. Admin commands short-circuit in `maybeHandleAdminCommand`. |
| Tool execution | `internal/app/runner_tools.go` `processToolCalls` -> `executeSingleToolCall` -> `executeToolCall` -> `executeToolInner` | Tools are `app` types (`tool_*.go`, `spawn_tool.go`, `tools.go`). Policy and HITL run as `agent.Hooks` registered by `SetupHooks`. |
| Scheduled jobs | `internal/cron/scheduler.go` `Scheduler.Run` -> `cron.Dispatcher` -> `internal/app/cron.go` `CronDispatcher.Dispatch` | `StartCron` (`app_servers.go`) runs only if cron is enabled and passes a `nil` checkpoint store, so cron sessions are ephemeral. Telegram delivery is in `cron_telegram.go`. |
| Memory write | Synchronous: `DispatchHandler.indexMemory` -> `memory.MemoryStore.Index` (`sqlite_store.go`). Asynchronous: `Consolidator.ConsolidateAsync` (`consolidator/consolidator.go`) | Transcript indexing runs in the request path if a memory store exists and the message is not skipped by `memory.ShouldSkipRAG`. Fact extraction (LLM call, dedup, optional vector indexing) runs in a background worker after the reply is produced. |
| Memory recall | `internal/app/runner_rag.go` `getRagBlock` | If vector search is enabled and a vector store and embedding provider exist: `hybridRagSearch` (`vector/hybrid.go` `HybridSearch`), falling back to `ftsSearch` (`MemoryStore.Search`, FTS5) on error. Otherwise FTS5 only. Vector search is optional. |
| Shutdown | `internal/app/app.go` `waitForShutdownTrigger`, `runOwnedConsolidation`, `runWithStackCleanup` | See "Shutdown Order" below. |

### Shutdown Order

1. On signal, context cancellation or a critical subsystem start failure, `waitForShutdownTrigger` marks readiness off, then calls `cancel()` so workers can begin cleanup, then `DrainGoroutines` waits on the shared `WaitGroup` for up to 5 seconds. A timeout is logged and shutdown proceeds.
2. `runOwnedConsolidation` then cancels again and calls `shutdownConsolidation`, which runs `Consolidator.Shutdown` with a 5 second join. Shutdown closes admission and waits for accepted consolidation workers; each worker is also bound to the runtime lifetime (`BindLifetime`) and has its own 30 second timeout.
3. `runWithStackCleanup` runs the stack cleanup (closing the stores) afterwards. Exception: if the join returned `consolidator.ErrDrainTimeout`, accepted workers still own the memory and vector stores, so cleanup is skipped, the retention is logged, and the process exits.
4. The OpenTelemetry provider shuts down last (deferred in `RunAgent`) with its own 5 second bound.

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

**Verification impact:** The no-CGO product build does not remove race testing
from the project. GitHub Actions remains the required CGO-capable race-detector
lane, while Windows no-CGO agents use the scoped non-race verification commands
documented in [Verification](verification.md).

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
- `internal/memory/sqlite_store.go` serializes index writes via mutex
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
- `internal/bot/pairing_handler.go` implements the pairing handler (`bot.NewPairingHandler`) that checks the pairing store
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
- Hooks are registered at startup in `internal/app/app.go` `SetupHooks` (currently the policy + HITL hooks)
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
- `StartCron` in `internal/app/app_servers.go` creates a new `SessionManager` with a `nil` checkpoint store and hands it to `NewCronDispatcher`
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
