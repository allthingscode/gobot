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
- **Advisory:** secrets roundtrip, liveness staleness, encryption key,
  plaintext secrets, HITL enabled, logs directory, startup time, telegram token
  (+ optional live probe), google oauth secrets, google token expiry, gmail
  token expiry, jobs directory (+ job count), browser availability,
  authorization (count of authorized users), vendor directory guard, memory
  footprint, local latency snapshot, cron job health, storage sizes, and gemini
  live probe.
- **Resilience:** per circuit breaker - `state, successes, failures, rejections`
  (`checkResilience`), plus a migration warning for old-format breaker durations.
- **Concurrency:** per session lock - `locked`, current hold age, `contention`,
  `max_wait`, `total_hold` (`checkConcurrency`, fed by
  `agent.GetLockMetrics`). Locks held longer than 60s produce an advisory,
  non-critical warning before the default 120s deadlock timeout.

The doctor also surfaces the elapsed wall-clock time for the check run itself.
The dashboard metrics page now summarizes memory, latency, startup time,
storage growth, cron health, and session-lock state for operators who need the
same current-state signals in the web UI.

### 1.3 Session lock metrics (`internal/agent/lock_metrics.go`)

`LockStatus` tracks, per session key: `IsLocked`, `AcquiredAt`, `WaitCount`,
`TotalWaitTime`, `TotalHoldTime`, `ContentionCount`, `MaxWaitTime`, and a
`HolderStack` snapshot captured when a wait exceeds 5s. `GetLockMetrics()`
returns a snapshot consumed by `doctor`, debug endpoints, and the dashboard
metrics page.

### 1.4 Cron job health (`internal/cron`)

`JobState` (`internal/cron/cron.go`) persists per job in `jobs.json`:
`LastRunAtMS`, `NextRunAtMS`, `RunCount`, `SuccessCount`, `FailureCount`. The
scheduler increments success/failure counters after each dispatch and logs
triggers and dispatch failures. These counters are durable and are surfaced in
`doctor` through the `cron` check. They are also visible on the dashboard cron
page when the running scheduler is wired into the gateway; otherwise the page
falls back to configured cron tasks.

### 1.5 OpenTelemetry (opt-in, `internal/observability`)

When an OTLP exporter is configured, the `Provider` records:

- `tokenCounter` — total tokens consumed by LLM calls.
- `toolHistogram` — tool-execution duration (seconds).
- `consolidationsTriggered`, `factsExtracted`, `factsIndexed`, `factsSkipped`.

`DispatchTracer` (`middleware.go`) wraps bot/agent/provider/tool/memory
operations in spans and attaches `duration_ms` attributes for provider and tool
calls. This is **opt-in** and intended for external collectors, not the default
local operator experience.

### 1.6 Local latency snapshot (`workspace/latency.json`)

`DispatchTracer` also records a bounded in-process rolling window for local
latency metrics and persists a compact snapshot to
`<storage>/workspace/latency.json`. The file contains recent counts, P50, P99,
and last-updated timestamps for `agent.dispatch`, `telegram.dispatch`, and
`tool.execute`. `gobot doctor` reads this file without starting runtime services
and reports missing/no-sample data distinctly from measured latency.

### 1.7 Web dashboard (`internal/gateway/dash`)

The gateway dashboard is mounted at `/dash/` when the gateway is enabled. It is
no longer only a live log viewer. Current pages are:

| Page | Route | Current surface |
|---|---|---|
| Home | `/dash/` | Online status, process uptime, version, and an embedded quick doctor diagnostic. |
| Doctor | `/dash/doctor` | Runs local `doctor.GetResults` and renders current `[OK]/[WRN]/[ERR]` checks. |
| Cron | `/dash/cron` | Shows live scheduler jobs when available, including schedule, last run, next run, and status; otherwise shows configured tasks. |
| Sessions | `/dash/sessions` | Lists resumable checkpoint threads with model, iteration, and last-updated timestamp. |
| Memory | `/dash/memory` and `/dash/memory/search` | Shows indexed fact count and searches long-term memory. |
| Logs | `/dash/logs` | Tails recent live or file-backed structured logs with level filtering. |
| Metrics | `/dash/metrics` | Shows compact operator panels for local latency P50/P99, process memory, storage size, startup time, and cron health. |

The metrics page reads the same local snapshots and read-only probes used by
`doctor`; it does not start external collectors or background services.

---

## 2. Core Metrics (Minimal Set for Operator Confidence)

| Metric | Purpose | Collection | Status | Surface |
|---|---|---|---|---|
| **Memory footprint** (RSS or heap alloc at startup and idle) | Detect leaks / bloat; confirm small footprint | `runtime.ReadMemStats` (HeapAlloc/Sys) sampled at boot and periodically | Collected (doctor line + boot DEBUG log) and surfaced on `/dash/metrics` | `doctor` line + dashboard metrics panel + DEBUG log at boot |
| **Message latency** (P50, P99 per user request) | UX responsiveness; spot regressions | `DispatchTracer` records bounded local windows for agent, Telegram, and tool timings; OTel remains opt-in for collectors | Collected locally (`workspace/latency.json`) and surfaced in `doctor` plus `/dash/metrics` | `doctor` line + dashboard metrics panel + OTel histogram/traces for collectors |
| **Cron job health** (last run, next run, failure count) | Confirm scheduled work runs; catch silent failures | Already persisted in `JobState` | Collected; surfaced in `doctor`, `/dash/cron`, and `/dash/metrics` | `doctor` check + dashboard cron table + dashboard metrics panel |
| **Startup time** (process start -> ready/listening) | Detect slow boots / init regressions | Capture `time.Now()` at `RunAgent` entry; log and persist delta when bot is ready/listening | Collected (INFO log + `doctor` detail) and surfaced on `/dash/metrics` | INFO log at ready + `doctor` detail + dashboard metrics panel |
| **Long-running session duration** (hang detection) | Detect stuck sessions / deadlocks | Derive current hold age from lock `AcquiredAt`; flag sessions held beyond the 60s stale threshold | Collected and surfaced as advisory, non-critical stale-lock warnings | `doctor` lock metrics + `/dash/metrics` Session Locks panel + WARN/ERROR logs |
| **Storage database size** (SQLite) | Detect unbounded growth of checkpoint/memory DBs | `os.Stat` the SQLite file(s) or `PRAGMA page_count * page_size` | Collected (doctor line) and surfaced on `/dash/metrics` | `doctor` line (C-337); dashboard metrics panel |

The dashboard metric panels referenced above are now shipped on `/dash/metrics`
for memory, local latency, cron health, startup time, storage size, and session
locks. Missing latency/startup files, absent stores, and absent lock metrics are
rendered as not recorded or absent, not as zero-valued measurements.

---

## 3. Recommended Surface Points (per metric)

- **Memory footprint** → `doctor` (one-line `[OK] memory — heap NN MiB, sys NN
  MiB`), the `/dash/metrics` memory panel, and a DEBUG log line at boot. Not an ERROR/WARN
  unless a configurable ceiling is exceeded.
  - **Measured cold idle (2026-06-24, current build):** ~23 MB Working Set
    (gateway only, Telegram off, empty workspace), sampled to stability via
    `Get-Process WorkingSet64` against an isolated empty `GOBOT_HOME`, and
    cross-checked with the C-330 instrumentation: boot DEBUG `gobot: boot
    memory` log (`heap_alloc_mib=3.3 sys_mib=11.6`) and the `gobot doctor`
    memory line (`heap 3.4 MiB, sys 15.6 MiB`). Rises to ~24-25 MB with all
    in-process subsystems enabled. The live Go heap is only ~3 MB; the balance
    is Go-runtime + mapped-binary baseline, so GC tuning is not the lever.
    Warm/loaded RSS scales with the in-memory vector index (chromem-go holds
    embeddings resident). Measured (R-015) at gobot's 768-dim embeddings: **warm
    RSS ~= cold ~23 MB + (fact_count x ~3.6 KB)** live heap - the 768 x 4 = 3,072 B
    embedding plus ~16% chromem document/map overhead (~3,541 B/vector measured at
    5k). A full re-index transiently spikes process RSS to ~2-2.6x the live index
    (chromem normalizes each embedding into a second slice) before the runtime
    returns it to the OS. The figure is re-verifiable in CI via
    `TestWarmFootprintPerVector` in `internal/memory/vector` - the warm analogue of
    the C-330/C-331 cold instrumentation. This measured cold figure supersedes the
    prior unsourced "72.59 MB idle" number; see the README "Footprint" section for
    the full methodology.
- **Message latency (P50/P99)** → `doctor` line from
  `<storage>/workspace/latency.json`, dashboard panel for operators, and OTel
  histogram/traces for external collectors. Local snapshots are bounded and
  compact; empty snapshots are reported as no samples rather than zero latency.
  Do not spam logs per request; log only when a request exceeds a slow threshold
  (WARN).
- **Cron job health** → `doctor` `cron` line (C-332) reading `JobState` from
  `{StorageRoot}/workspace/jobs.json` read-only: `[OK] cron - N jobs, all healthy,
  next run in <dur>` (or `no scheduled jobs`), and `[WARN]` (advisory, non-critical)
  when any job has a non-zero `FailureCount`. The dashboard cron page shows a
  live job table when the scheduler is wired, with configured-task fallback.
  already exists in `jobs.json`.
- **Startup time** → single INFO log line at "ready/listening" and a `doctor`
  detail from `<storage>/workspace/startup.json`. Surfaced on `/dash/metrics`; missing markers are shown as not recorded rather than as zero.
- **Long-running session duration** -> lock metrics expose current locked
  state, current hold age, `TotalHoldTime`, and contention/max-wait data to
  `doctor` and `/dash/metrics`. A held lock older than 60s is reported as an
  advisory, non-critical warning with remediation; the 5s holder-stack capture
  remains log/metrics data and is not dumped into doctor/dashboard output.
- **Storage database size** → `doctor` line and the `/dash/metrics` storage panel. WARN only past the existing advisory threshold; missing stores are shown as absent rather than zero-sized measurements.
- **Token consumption** (existing OTel counter) → intentionally **not** surfaced
  in `doctor`/dashboard by default; it is cost telemetry for external collectors,
  not a stability signal.

---

## 4. Where Operators Find Metrics Today

| Surface | Command / Location | What it shows |
|---|---|---|
| Logs | `gobot logs [--filter --since --follow]` | All structured slog records, including cron triggers, lock contention, dashboard start |
| Doctor | `gobot doctor` | Health checks incl. startup time, memory footprint, local latency P50/P99, cron health, storage sizes, circuit-breaker stats, and live session-lock contention metrics |
| Cron state | `<storage>/workspace/jobs.json` (`JobState`) | Per-job run/success/failure counts, last/next run; read by `doctor` and the live dashboard cron page |
| Latency state | `<storage>/workspace/latency.json` (`LatencySnapshot`) | Recent bounded P50/P99 samples for agent, Telegram, and tool execution |
| Dashboard | gateway dashboard under `/dash/` | Home, operator metrics, doctor diagnostics, cron jobs, resumable sessions, memory search, and logs |
| OTel | external OTLP collector (opt-in) | Token counter, tool-duration histogram, memory/consolidation counters, dispatch spans; separate from local latency snapshots |

---

## 5. Notes & Constraints

- Keep the core set small; do not preempt the P1 stability audits (C-302,
  C-303, C-305).
- Shipped doctor checks and `/dash/metrics` cover memory, local latency, startup time, cron health, and storage sizes. Remaining observability gaps are trend views and operator alerting, not missing current-state instrumentation.
- Memory and db-size checks are cheap (`runtime.ReadMemStats`, `os.Stat`) and
  must never block startup.
