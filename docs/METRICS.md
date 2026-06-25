# Metrics Reference

This document is the canonical reference for gobot's runtime footprint and
operator/user-experience (UX) metrics. It records what is **already** observable
today, defines the **minimal core set** of metrics operators need for
confidence, and specifies **where each metric should surface** (logs, the
`doctor` command, the web dashboard, tests, or intentionally not surfaced).

Scope note (C-228): this is a discovery-and-spec document. It introduces no new
instrumentation. Any missing instrumentation called out below is future work for
a later Architect cycle and is explicitly out of scope here.

Design principle: **stability-first, minimal footprint.** Prefer a small set of
high-signal metrics that an operator can read at a glance over exhaustive
telemetry that adds maintenance burden.

---

## 1. Current Observability Audit

### 1.1 Structured logging (`log/slog`)

gobot logs structured records via the standard library `log/slog`. Operators
read them through the `gobot logs` command (`cmd/gobot/logs.go`), which supports:

- `--lines N` — tail the last N lines (default 100).
- `--filter LEVEL` — filter by `ERROR`, `WARN`, `INFO`, `DEBUG`.
- `--since DURATION` — only show records newer than e.g. `1h`, `30m`.
- `--follow` — stream new records as they are written.
- `--list` — list available log files with size and mtime.

Notable log-emitted signals already present:

| Signal | Source | Level |
|---|---|---|
| Lock contention (session, wait_time) | `internal/agent/lock_metrics.go` | WARN |
| Session lock timeout / possible deadlock | `internal/agent/lock_metrics.go` | ERROR |
| Cron job triggered (id, name) | `internal/cron/scheduler.go` | INFO |
| Cron job dispatch failed (id, err) | `internal/cron/scheduler.go` | ERROR |
| Cron new job scheduled (id, nextRunAt) | `internal/cron/scheduler.go` | INFO |
| Persistent `jobs.json` reload failure (>5m) | `internal/cron/scheduler.go` | WARN |
| Dashboard server start (addr) | `internal/dashboard/server.go` | INFO |

### 1.2 `gobot doctor` health checks

`doctor.Run` (`internal/doctor/doctor.go`, wired via
`cmd/gobot/cli_runtime.go`) runs a suite of checks at startup (non-fatal
warnings) and on demand. Each check returns `{name, ok, detail, remediation,
critical}` and the report prints `[OK]/[WRN]/[ERR]` plus a total-checks-and-
elapsed line.

Checks present today:

- **Critical:** storage root, workspace writable, security store, llm api key.
- **Advisory:** encryption key, plaintext secrets, HITL enabled, logs directory,
  telegram token (+ optional live probe), google oauth secrets, google token
  expiry, gmail token expiry, jobs directory (+ job count), browser
  availability, authorization (count of authorized users), gemini live probe.
- **Resilience:** per circuit breaker — `state, successes, failures, rejections`
  (`checkResilience`), plus a migration warning for old-format breaker durations.
- **Concurrency:** per session lock — `contention, max_wait, total_hold`
  (`checkConcurrency`, fed by `agent.GetLockMetrics`).

The doctor surfaces the elapsed wall-clock time for the check run itself, but
**not** process startup time, memory footprint, or database size.

### 1.3 Session lock metrics (`internal/agent/lock_metrics.go`)

`LockStatus` tracks, per session key: `IsLocked`, `AcquiredAt`, `WaitCount`,
`TotalWaitTime`, `TotalHoldTime`, `ContentionCount`, `MaxWaitTime`, and a
`HolderStack` snapshot captured when a wait exceeds 5s. `GetLockMetrics()`
returns a snapshot consumed by `doctor` and debug endpoints.

### 1.4 Cron job health (`internal/cron`)

`JobState` (`internal/cron/cron.go`) persists per job in `jobs.json`:
`LastRunAtMS`, `NextRunAtMS`, `RunCount`, `SuccessCount`, `FailureCount`. The
scheduler increments success/failure counters after each dispatch and logs
triggers and dispatch failures. These counters are durable but are **not**
surfaced in `doctor` output today.

### 1.5 OpenTelemetry (opt-in, `internal/observability`)

When an OTLP exporter is configured, the `Provider` records:

- `tokenCounter` — total tokens consumed by LLM calls.
- `toolHistogram` — tool-execution duration (seconds).
- `consolidationsTriggered`, `factsExtracted`, `factsIndexed`, `factsSkipped`.

`DispatchTracer` (`middleware.go`) wraps bot/agent/provider/tool/memory
operations in spans and attaches `duration_ms` attributes for provider and tool
calls. This is **opt-in** and intended for external collectors, not the default
local operator experience.

### 1.6 Web dashboard (F-139, `internal/dashboard`)

The dashboard server streams structured log entries to the browser over SSE
(`/events`) with a backlog replay, plus a static `index.html`. It is a **live
log viewer** today; it does not yet render dedicated metric panels (latency,
memory, cron health). It is the natural future surface for the core metrics
below.

---

## 2. Core Metrics (Minimal Set for Operator Confidence)

| Metric | Purpose | Collection | Status | Surface |
|---|---|---|---|---|
| **Memory footprint** (RSS or heap alloc at startup and idle) | Detect leaks / bloat; confirm small footprint | `runtime.ReadMemStats` (HeapAlloc/Sys) sampled at boot and periodically | Collected (doctor line + boot DEBUG log); dashboard panel pending | `doctor` line + dashboard panel + DEBUG log at boot |
| **Message latency** (P50, P99 per user request) | UX responsiveness; spot regressions | Time agent dispatch end-to-end; aggregate quantiles (extend `DispatchTracer`/OTel histogram) | Span `duration_ms` exists per call; no P50/P99 aggregation | Dashboard panel; OTel histogram for collectors |
| **Cron job health** (last run, next run, failure count) | Confirm scheduled work runs; catch silent failures | Already persisted in `JobState` | Collected; surfaced in `doctor` (C-332); dashboard panel pending | `doctor` check + dashboard panel |
| **Startup time** (process start → ready/listening) | Detect slow boots / init regressions | Capture `time.Now()` at `main` entry; log delta when bot is listening | Not collected | INFO log at ready + `doctor` detail |
| **Long-running session duration** (hang detection) | Detect stuck sessions / deadlocks | Derive from lock `AcquiredAt`/`TotalHoldTime`; flag sessions held beyond threshold | Partial: lock hold time + deadlock timeout exist | `doctor` advisory + WARN log (extends existing 5s contention warn) |
| **Storage database size** (SQLite) | Detect unbounded growth of checkpoint/memory DBs | `os.Stat` the SQLite file(s) or `PRAGMA page_count * page_size` | Not collected | `doctor` line + dashboard panel |

---

## 3. Recommended Surface Points (per metric)

- **Memory footprint** → `doctor` (one-line `[OK] memory — heap NN MiB, sys NN
  MiB`), a dashboard gauge, and a DEBUG log line at boot. Not an ERROR/WARN
  unless a configurable ceiling is exceeded.
  - **Measured cold idle (2026-06-24, current build):** ~23 MB Working Set
    (gateway only, Telegram off, empty workspace), sampled to stability via
    `Get-Process WorkingSet64` against an isolated empty `GOBOT_HOME`, and
    cross-checked with the C-330 instrumentation: boot DEBUG `gobot: boot
    memory` log (`heap_alloc_mib=3.3 sys_mib=11.6`) and the `gobot doctor`
    memory line (`heap 3.4 MiB, sys 15.6 MiB`). Rises to ~24-25 MB with all
    in-process subsystems enabled. The live Go heap is only ~3 MB; the balance
    is Go-runtime + mapped-binary baseline, so GC tuning is not the lever.
    Warm/loaded RSS scales with the in-memory vector index (chromem-go is
    resident by design) and is not yet separately quantified. This measured
    figure supersedes the prior unsourced "72.59 MB idle" number; see the README
    "Footprint" section and `.crucible/research/R-013_findings.md` for the full
    methodology.
- **Message latency (P50/P99)** → dashboard panel for operators; OTel histogram
  for external collectors. Do not spam logs per request; log only when a request
  exceeds a slow threshold (WARN).
- **Cron job health** → `doctor` `cron` line (C-332) reading `JobState` from
  `{StorageRoot}/workspace/jobs.json` read-only: `[OK] cron - N jobs, all healthy,
  next run in <dur>` (or `no scheduled jobs`), and `[WARN]` (advisory, non-critical)
  when any job has a non-zero `FailureCount`. Dashboard panel still pending.
  (`last/next run, success/failure counts`) and a dashboard table. Source data
  already exists in `jobs.json`.
- **Startup time** → single INFO log line at "ready/listening" and a `doctor`
  detail. Not surfaced on the dashboard (one-shot value).
- **Long-running session duration** → extend the existing lock-contention WARN
  to also flag long holds; advisory `doctor` line. Keep the 5s holder-stack
  capture as-is.
- **Storage database size** → `doctor` line and a dashboard gauge. WARN only past
  a configurable threshold.
- **Token consumption** (existing OTel counter) → intentionally **not** surfaced
  in `doctor`/dashboard by default; it is cost telemetry for external collectors,
  not a stability signal.

---

## 4. Where Operators Find Metrics Today

| Surface | Command / Location | What it shows |
|---|---|---|
| Logs | `gobot logs [--filter --since --follow]` | All structured slog records, including cron triggers, lock contention, dashboard start |
| Doctor | `gobot doctor` | Health checks incl. circuit-breaker stats and live session-lock contention metrics |
| Cron state | `<storage>/workspace/jobs.json` (`JobState`) | Per-job run/success/failure counts, last/next run |
| Dashboard | dashboard server `/` and `/events` (F-139) | Live SSE stream of structured log entries |
| OTel | external OTLP collector (opt-in) | Token counter, tool-duration histogram, memory/consolidation counters, dispatch spans |

---

## 5. Notes & Constraints

- Keep the core set small; do not preempt the P1 stability audits (C-302,
  C-303, C-305).
- This spec is the input to F-139 dashboard metric panels and to a future
  Architect cycle that adds the missing instrumentation (memory, latency
  quantiles, startup time, db size, cron-health doctor check).
- Memory and db-size checks should be cheap (`runtime.ReadMemStats`, `os.Stat`)
  and must never block startup.
