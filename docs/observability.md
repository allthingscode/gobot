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
- **Cron health.** Confirm scheduled work is running via cron `JobState`
  (`last/next run`, `success/failure` counts) in `<storage>/workspace/jobs.json`
  and the `cron: triggering job` / `cron: job dispatch failed` log lines.
- **Concurrency.** Watch for `agent: lock contention` (WARN) and
  `session lock timeout — possible deadlock` (ERROR). The `doctor` concurrency
  section reports live per-session contention, max wait, and total hold time.
- **Dashboard.** When the F-139 dashboard is running, use it as the live log
  surface; future metric panels (memory, latency, cron health) will appear here
  per `docs/METRICS.md` §2–3.

### Core metrics an operator should be able to answer

An operator persona should be able to report on the minimal core set defined in
`docs/METRICS.md`:

1. Memory footprint (RSS / heap alloc) at startup and idle.
2. Message latency (P50 / P99) for user requests.
3. Cron job health (last run, next run, failure count).
4. Startup time (process to ready/listening).
5. Long-running session duration (hang/deadlock detection).
6. Storage database size (SQLite growth).

Where a metric is not yet surfaced (see the Status column in `docs/METRICS.md`),
the operator should say so explicitly rather than guess. Adding the missing
instrumentation is a future Architect task, not an operator action.

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
