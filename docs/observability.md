# Agent Operator Guide (Observability Expectations)

Guidance for AI operator personas (and humans acting as operators) running and
maintaining gobot. This complements `docs/architecture.md` and the metrics
reference in `docs/METRICS.md`.

> Note: this is the project's operator/`AGENTS.md`-equivalent guide. The repo
> `.gitignore` excludes any file literally named `AGENTS.md`, so the operator
> observability guidance lives here as `docs/observability.md` instead.

## Observability Expectations

When operating gobot, an AI operator persona is expected to **observe before
acting** and to rely on the established surfaces rather than ad-hoc inspection.

### What to check, and where

- **Health first.** Run `gobot doctor` before assuming the system is healthy.
  Treat `[ERR]` (critical) as blocking and follow the printed remediation.
  Treat `[WRN]` as advisory but do not ignore repeated warnings.
- **Logs for evidence.** Use `gobot logs --filter ERROR --since 1h` to triage
  recent failures and `--follow` to watch live behavior. All operator-relevant
  events are structured `log/slog` records (see `docs/METRICS.md` §1.1).
- **Cron health.** Confirm scheduled work is running through the `gobot doctor`
  cron check and, when the gateway dashboard is enabled, `/dash/cron`. The
  source data lives in `<storage>/workspace/jobs.json` and includes
  `last/next run` plus `success/failure` counts; logs still carry
  `cron: triggering job` and `cron: job dispatch failed` events.
- **Latency.** Use the `gobot doctor` latency line for recent local P50/P99
  samples. It is backed by `<storage>/workspace/latency.json` and works without
  an external telemetry collector. Missing data means the process has not
  recorded a snapshot yet; `recorded, no samples yet` means the marker exists
  but no dispatch/tool timing has been sampled.
- **Concurrency.** Watch for `agent: lock contention` (WARN) and
  `session lock timeout - possible deadlock` (ERROR). The `doctor` concurrency
  section reports live per-session contention, max wait, total hold time, and
  enough lock state to identify long-held sessions. A dedicated stale-lock
  dashboard alert remains future work.
- **Dashboard.** When the gateway dashboard is running, use `/dash/` for the
  system overview and quick doctor diagnostic, `/dash/metrics` for compact
  operator metric panels, `/dash/doctor` for local health checks, `/dash/cron`
  for scheduled jobs, `/dash/sessions` for resumable threads, `/dash/memory` for
  fact count and memory search, and `/dash/logs` for recent structured logs.

### Core metrics an operator should be able to answer

An operator persona should be able to report on the minimal core set defined in
`docs/METRICS.md`:

1. Memory footprint (RSS / heap alloc) at startup and idle.
2. Message latency (P50 / P99) for user requests.
3. Cron job health (last run, next run, failure count).
4. Startup time (process to ready/listening).
5. Long-running session duration (hang/deadlock detection).
6. Storage database size (SQLite growth).

Memory footprint, message latency, cron job health, startup time, and storage
sizes are surfaced by `doctor` and summarized on `/dash/metrics`. Long-running
session duration is represented through the existing lock metrics rather than a
dedicated duration panel. Missing latency/startup history should be reported as
not recorded; operators should not infer zero values from absent local snapshot
files.

### Operating principles

- **Stability first.** Prefer the smallest action that restores or confirms
  health. Do not introduce new telemetry or instrumentation as an operator;
  route that to an implementation cycle.
- **Use remediations.** The `doctor` `Remediation` field is the sanctioned fix
  path — follow it before improvising.
- **No silent failures.** If cron failure counts are climbing or a breaker is
  `open`, surface it; do not suppress.
- **Minimal footprint.** Memory and database-size observations must use cheap
  probes (`runtime.ReadMemStats`, `os.Stat`) and must never block startup.
