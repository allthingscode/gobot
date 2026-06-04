# 30-Day Windows Soak-Test Plan

This document is an operator runbook for executing a 30-day zero-maintenance soak
test of Gobot on Windows. It validates that the components delivered under C-303
(automated startup, crash recovery, log rotation, secrets decryption, OAuth token
refresh, cron resumption, heartbeat monitoring, and doctor pre-flight checks) work
together for a full month without manual intervention.

The plan is self-contained: a Windows operator with basic admin skills and a
dedicated test machine should be able to run it unaided. It assumes the build under
test is the current production binary used as-is (no source changes are in scope).

> **Source of truth for behavior.** Every check below is grounded in gobot's
> actual implementation. Key references:
> - Startup / restart loop and secrets pre-flight: `start_gobot.ps1`
> - Task Scheduler registration: `scripts/install_task.ps1`
> - Run loop and background goroutines: `internal/app/app.go`
> - Heartbeat + LIVENESS file: `internal/app/heartbeat.go`
> - Pre-flight diagnostics: `internal/doctor/doctor.go`
> - Deployment + DPAPI + cron semantics: `docs/deployment.md`
> - Secrets / DPAPI model: `docs/security.md`

---

## 0. Test Parameters & Conventions

| Item | Value |
|---|---|
| Duration | 30 consecutive days (720 hours) |
| Platform | Windows 11 / Windows 10, dedicated test machine |
| Run account | The interactive Windows user that performed `gobot authorize` / `gobot reauth` |
| Launch mechanism | Task Scheduler task "Gobot Strategic Edition" (`-AtLogOn`), registered via `scripts\install_task.ps1` |
| Heartbeat interval | Default 15 min (`config.HeartbeatInterval()` default; `Heartbeat.Interval` in `config.json`) |
| LIVENESS staleness threshold | 2x heartbeat interval = 30 min (doctor `checkLivenessStaleness`) |
| Storage root | `<GOBOT_STORAGE>` (or `~/gobot_data` default); referred to below as `<STORAGE>` |
| Key log | `<STORAGE>\logs\gobot.log` (rotated by lumberjack) |
| Startup log | `<STORAGE>\logs\gobot-startup.log` |
| Liveness file | `<STORAGE>\LIVENESS` |
| PID lock | `<STORAGE>\logs\gobot.pid` |

**Daily operator burden.** "Zero-maintenance" refers to gobot, not to the operator.
The operator performs a brief (~5 min) **read-only** observation each day (Section 3)
and records the day's signals. The operator must NOT restart the service, edit
config, re-run `gobot reauth`, or otherwise touch the deployment except under the
explicit rollback triggers in Section 6. Any such intervention is itself a soak
failure and must be logged.

**Logging convention.** Maintain a `soak-log.csv` (or spreadsheet) with one row per
day: date, LIVENESS age at check, error-line count for the day, heartbeat alert
count, Task Scheduler last-run result, and a free-text notes field. This log is the
primary evidence artifact for the pass/fail decision in Section 4.

---

## 1. Pre-Soak Checklist (Day 0)

Complete every item below **before** starting the 30-day clock. If any **blocking**
item fails, stop and remediate; do not start the soak.

### 1.1 Build & install

- [ ] Build the binary: `.\scripts\build.ps1` (produces `bin\gobot.exe`;
      `start_gobot.ps1` resolves `bin\gobot.exe` first, then project root).
- [ ] Confirm `bin\gobot.exe` exists and `.\bin\gobot.exe --version` (or the build
      banner) reports the expected build.

### 1.2 Doctor pass criteria (BLOCKING)

Run the pre-flight health check and capture full output to the soak evidence folder:

```powershell
.\bin\gobot.exe doctor | Tee-Object -FilePath .\soak-evidence\doctor-day0.txt
```

Pass criteria, mapped to `internal/doctor/doctor.go`:

- [ ] **No `[ERR]` lines.** Doctor returns non-zero only on a *critical* failure.
      The critical checks (must all be `OK`) are: `storage root`, `workspace
      writable`, `security store`, and `llm api key`. A non-zero exit / any `[ERR]`
      is a hard stop.
- [ ] **`secrets roundtrip` is `OK`** showing `DPAPI Set->Get->Delete OK for user
      "<you>"`. This advisory check proves the run account can encrypt/decrypt under
      DPAPI. Treat a `WRN` here as **blocking for the soak** even though it does not
      block startup, because it predicts mid-run secret failures.
- [ ] **`security store` reports `using Windows DPAPI`** (confirms the DPAPI path,
      not a stray AES key file).
- [ ] **`liveness staleness`** is `OK` (expected `no LIVENESS file yet (cold start)`
      on a fresh machine).
- [ ] Review remaining advisory (`WRN`) checks and record them. Acceptable warnings
      for an unattended run include `browser`, `jobs directory (no .md jobs)`, and
      OAuth token checks if Google/Gmail is not used. `human-in-the-loop` should be
      `OK` (HITL enabled) if any high-risk tools are configured.

### 1.3 Secrets test pass (BLOCKING)

This is the same gate `start_gobot.ps1` runs at every launch, so it must pass under
the soak account first:

```powershell
.\bin\gobot.exe secrets test
```

- [ ] Output contains `Secrets pre-flight PASS for user "<you>" on windows.`
- [ ] The account printed matches the account that will own the Task Scheduler task.
      If it fails (a `CryptUnprotectData` error), the task account does not match the
      authorizing account  -  fix per `docs/security.md` section 6 before proceeding.

### 1.4 Environment validation (BLOCKING)

- [ ] **Storage root is single and explicit.** Decide on `config.json`
      (`strategic_edition.storage_root`) **or** `GOBOT_STORAGE`. Per
      `docs/deployment.md`, prefer `config.json` so interactive and scheduled runs
      never split-brain. Confirm with `.\bin\gobot.exe config storage-root`.
- [ ] **API keys/secrets are in the vault, not plaintext config.** Doctor's
      `plaintext secrets` check must be `OK`.
- [ ] **Authorization present.** Doctor `authorization` should report at least one
      authorized user (`gobot authorize <chat-id>`), otherwise the bot drops all
      inbound messages.
- [ ] **OAuth tokens valid (if Google/Gmail used).** `google token` / `gmail token`
      checks show a valid or auto-refreshable expiry; if not, run `.\bin\gobot.exe
      reauth` before the soak.
- [ ] **Power management.** Configure the test machine's power plan so it does NOT
      sleep/hibernate (or document that overnight sleep is part of the test). Note:
      missed cron jobs are **not** replayed on resume (see `docs/deployment.md`,
      "Missed jobs are NOT replayed on startup")  -  this is expected behavior, not a
      failure.
- [ ] **Disk headroom.** Record free space on the `<STORAGE>` volume; ensure at least
      several GB free so 30 days of rotated logs cannot fill the disk.

### 1.5 Task registration & baseline

- [ ] Register the task as the soak account: `.\scripts\install_task.ps1`
      (registers "Gobot Strategic Edition", `-AtLogOn`, `RestartCount 5`,
      `RestartInterval 2 min`, `RunLevel Highest`). Confirm the printed
      `GOBOT_STORAGE` line matches your intended storage root.
- [ ] Reboot (or log off/on) and confirm gobot starts automatically. Verify the
      startup banner / `gobot ready` line and a fresh `LIVENESS` file appears within
      one heartbeat interval.
- [ ] Record **Day 0 baseline**: timestamp, doctor output, free disk, current
      `gobot.log` size, and the Task Scheduler task's first successful run.

**Start the 30-day clock only after every blocking item above passes.**

---

## 2. Validation Signals to Collect During the Run

These are the four core signals defined by the acceptance criteria, each tied to a
concrete on-disk or OS artifact gobot actually produces.

### 2.1 LIVENESS file staleness

- **Source:** `internal/app/heartbeat.go` `writeLivenessFile()` rewrites
  `<STORAGE>\LIVENESS` on **every** heartbeat tick with content
  `ok <RFC3339-UTC> failures=<n>`.
- **Collect daily:**
  ```powershell
  $lv = Get-Item "$STORAGE\LIVENESS"
  $age = (Get-Date) - $lv.LastWriteTime
  Get-Content $lv  # shows timestamp + failures=N
  ```
- **Healthy:** age < 2x heartbeat interval (default < 30 min) and `failures=0`.
  An age above the 30-min threshold is exactly what doctor's `liveness staleness`
  check flags as a stalled heartbeat goroutine.

### 2.2 Log error rate

- **Source:** `<STORAGE>\logs\gobot.log` (structured slog text/JSON, rotated by
  lumberjack: default 50 MB max, 5 backups, 30-day age, compressed  -  see
  `SetupLogging` in `internal/app/app.go`). Rotated/compressed backups must be
  included when counting.
- **Collect daily:** count error-level lines for the day. For text logs:
  ```powershell
  (Select-String -Path "$STORAGE\logs\gobot.log" -Pattern 'level=ERROR').Count
  ```
  Also note any `heartbeat: probe failed` (WARN) and panic-recovery markers (the run
  loop wraps every goroutine in `RecoverWithStack`, so a recovered panic appears in
  the log rather than crashing the process).
- **Healthy:** error lines are zero or limited to transient, self-recovering events
  (e.g., a single network blip followed by recovery), with no repeating error loop.

### 2.3 Heartbeat alert count

- **Source:** When a probe fails, `heartbeat.go` logs `heartbeat: probe failed` and
  (if a chat ID is configured) sends a Telegram `[gobot] Partial Outage` alert. The
  on-disk signal is the WARN log line plus `failures=<n>` in the LIVENESS file.
- **Collect daily:**
  ```powershell
  (Select-String -Path "$STORAGE\logs\gobot.log" -Pattern 'heartbeat: probe failed').Count
  ```
  Record any Telegram "Partial Outage" alerts received and whether the next tick
  cleared them (`heartbeat: all probes OK`).
- **Healthy:** alerts are rare, correlated with a known external outage, and
  self-clear on the next interval without operator action.

### 2.4 Task Scheduler run history

- **Source:** Windows Task Scheduler history for task "Gobot Strategic Edition".
- **Collect daily:**
  ```powershell
  Get-ScheduledTaskInfo -TaskName "Gobot Strategic Edition" |
    Select-Object LastRunTime, LastTaskResult, NumberOfMissedRuns
  ```
- **Healthy:** `LastTaskResult` is `0`, the task shows as Running, and there are no
  unexpected re-launches. Because `start_gobot.ps1` runs its own internal
  restart-on-crash loop, a healthy soak typically shows the **task** launching once
  (at logon) while crash recovery happens inside the script; Task Scheduler-level
  restarts (its `RestartCount 5`) firing repeatedly indicates the wrapper itself is
  exiting and must be investigated.

---

## 3. Daily Operator Routine (~5 minutes, read-only)

Each day, without altering the deployment:

1. Confirm the process is alive: `Get-Process gobot` shows one process; the PID
   matches `<STORAGE>\logs\gobot.pid`.
2. Record LIVENESS age + `failures=` value (Section 2.1).
3. Record the day's ERROR line count and any new `probe failed` lines (2.2, 2.3).
4. Record Task Scheduler `LastTaskResult` and run count (2.4).
5. Note free disk on `<STORAGE>` volume and current `gobot.log` size.
6. Append a row to `soak-log.csv`. Flag anything abnormal but do NOT act unless a
   Section 6 rollback trigger is met.

Run `.\bin\gobot.exe doctor` once per week (read-only) and archive the output;
between weekly runs rely on the passive signals so you do not perturb the system.

---

## 4. Pass Criteria for a Successful 30-Day Completion

The soak **passes** only if all of the following hold across the full 30 days:

- [ ] **Uptime >= 99.5%.** Computed from LIVENESS continuity: total heartbeat ticks
      with a fresh LIVENESS write divided by expected ticks (one per interval over
      720 hours). Equivalently, total time with LIVENESS age over the 30-min
      staleness threshold must be under ~3.6 hours cumulative.
- [ ] **No manual intervention.** Zero operator restarts, config edits, reauths, or
      manual recoveries. Automatic in-process recovery (panic recovery, the
      `start_gobot.ps1` restart loop, OAuth auto-refresh, circuit-breaker recovery)
      does **not** count against this and is the expected mechanism.
- [ ] **Error threshold.** No sustained/looping ERROR condition. Transient errors
      that self-recover are acceptable; a repeating error every interval, or any
      unrecovered crash that leaves the process down, fails the soak.
- [ ] **Heartbeat health.** `failures=0` in LIVENESS for the vast majority of ticks;
      any `failures>0` windows are short, externally caused, and self-clear.
- [ ] **Task Scheduler clean.** `LastTaskResult = 0` throughout; no evidence the
      Task Scheduler wrapper itself repeatedly relaunched (internal script restarts
      are fine and expected).
- [ ] **Secrets remained accessible.** No `CryptUnprotectData` / DPAPI errors at any
      point; weekly doctor runs keep `secrets roundtrip` and `security store` `OK`.
- [ ] **Disk stable.** Log rotation kept `logs\` bounded; free space never fell into
      a danger zone (see Section 5.2 disk trigger).
- [ ] **Final doctor pass.** A Day-30 `gobot doctor` shows the same critical checks
      `OK` as Day 0.

Capture a **Day-30 closing report**: final doctor output, the completed
`soak-log.csv`, computed uptime %, and a list of every alert/error event with its
resolution.

---

## 5. Windows-Specific Checks

These target Windows failure modes that generic monitoring would miss.

### 5.1 Task Scheduler event-log verification

Beyond `Get-ScheduledTaskInfo`, verify the underlying Task Scheduler operational
event log (it has a bounded size and rolls over, so check periodically rather than
only at the end):

```powershell
Get-WinEvent -LogName "Microsoft-Windows-TaskScheduler/Operational" -MaxEvents 50 |
  Where-Object { $_.Message -match "Gobot Strategic Edition" } |
  Select-Object TimeCreated, Id, LevelDisplayName, Message
```

- [ ] Confirm logon-trigger launch events (action started / completed) appear.
- [ ] No repeated "task failed to start" / launch-failure events.
- [ ] Cross-check that the script's own `gobot-startup.log` shows matching
      network-check and secrets-pre-flight entries for each launch.
- [ ] Note that this event log is capacity-limited; if it wraps, rely on
      `gobot-startup.log` (which gobot appends to) for the full launch history.

### 5.2 DPAPI vault accessibility

The DPAPI vault (`<STORAGE>\workspace\dpapi_secrets.json`) is bound to the run
account's SID and cannot be decrypted by another account/machine (see
`docs/security.md` sections 3 & 6). Verify it stays accessible:

- [ ] Every launch implicitly verifies this: `start_gobot.ps1` runs `gobot secrets
      test` and **exits non-zero (no startup) if it fails**, writing the failure to
      `gobot-startup.log`. A clean soak therefore shows a passing pre-flight in that
      log on each launch.
- [ ] Weekly, confirm doctor's `secrets roundtrip` = `OK` and `security store` =
      `using Windows DPAPI`.
- [ ] Watch for any `CryptUnprotectData` error in `gobot.log` or
      `gobot-startup.log`  -  its appearance is an immediate rollback trigger (6.1),
      since it usually means a profile/SID change corrupted decryptability.

### 5.3 Network recovery after intermittent outage

gobot is designed to survive transient network loss without restarting:

- At launch, `start_gobot.ps1` `Wait-ForNetwork` does a bounded DNS probe
  (`dns.google`, 5 attempts x 3s, ~15s cap) then proceeds regardless, logging each
  attempt to `gobot-startup.log`.
- At runtime, the heartbeat probes (Telegram/Gemini/Gmail) report failures and the
  resilience circuit breakers (doctor `breaker:` checks) trip and recover.

**Test (perform once or twice mid-soak, then let it run unattended):**

- [ ] Disable the network adapter for ~2-5 minutes while gobot is running.
- [ ] Confirm the heartbeat logs `probe failed` and LIVENESS shows `failures>0`
      during the outage (and a Telegram Partial Outage alert if configured).
- [ ] Re-enable the network. Confirm the **next** heartbeat tick logs
      `heartbeat: all probes OK` and LIVENESS returns to `failures=0` **without** any
      restart or operator action.
- [ ] Confirm the gobot process never exited (same PID before and after) and any
      open circuit breaker returns to closed in a subsequent doctor run.

---

## 6. Rollback Plan for Mid-Run Failure

If a rollback trigger fires, the soak result is **FAIL** (or, for a clean re-baseline,
a documented restart). Record the trigger, timestamp, evidence, and action in the
soak log before doing anything. The deployment is documentation/config-driven and the
binary is used as-is, so "rollback" means restoring a known-good state, not reverting
code.

**Pre-soak safety baseline (capture on Day 0 so rollback is possible):**
- Offline plaintext export of every secret (`gobot secrets get <key>` per
  `docs/security.md` section 6) stored in a password manager.
- Copies of `config.json`, `client_secrets.json`, and (if preserving history)
  `gobot.db` / `memory.db`.

### 6.1 Secrets / DPAPI corruption

**Trigger:** `gobot secrets test` fails at launch (startup aborts, logged in
`gobot-startup.log`), or `CryptUnprotectData` errors appear, or doctor `secrets
roundtrip` flips to `WRN`/fail.

**Rollback:**
1. Stop the task (`Stop-ScheduledTask -TaskName "Gobot Strategic Edition"`).
2. Confirm the run account/SID is unchanged. If the account was renamed only (same
   SID), decryption should still work  -  re-test.
3. If the SID/profile genuinely changed (new account, profile migration, reinstall),
   the vault is unrecoverable per `docs/security.md`: delete the undecryptable
   `dpapi_secrets.json`, run `gobot init`, and re-set every secret from the Day-0
   offline export (`gobot secrets set ...`), then `gobot reauth` for Google/Gmail.
4. Re-run the full Section 1 pre-soak checklist before resuming; the 30-day clock
   restarts.

### 6.2 Disk full

**Trigger:** free space on the `<STORAGE>` volume crosses a danger threshold (e.g.,
< 1 GB or < 5%), or write errors (`workspace writable` / `logs directory`) appear in
doctor / `gobot.log`.

**Rollback:**
1. Stop the task to halt further writes.
2. Reclaim space: lumberjack already caps `gobot.log` (50 MB x 5 + compression), so
   the usual culprits are external  -  clear other apps' data, or move `<STORAGE>` to a
   larger volume by updating `strategic_edition.storage_root` (the most robust option
   per `docs/deployment.md`) and re-registering the task with `install_task.ps1`.
3. If the storage root moved, verify no split-brain (one storage root only) and that
   the DPAPI vault + databases moved with it.
4. Re-run pre-soak checks; resume and restart the clock.

### 6.3 Persistent network failure

**Trigger:** heartbeat `failures>0` and circuit breakers stay open for an extended,
**non-transient** period (e.g., hours), distinguishing a real outage from the
self-recovering blips that Section 5.3 expects gobot to absorb.

**Rollback:**
1. First confirm it is an environment problem, not gobot: from the same machine,
   independently resolve `dns.google` and reach the provider endpoints. gobot is
   *expected* to recover on its own once connectivity returns, so do **not** restart
   it for a recoverable outage.
2. If connectivity is genuinely, persistently broken, the test environment no longer
   meets the soak's "always-on, networked" precondition  -  pause the soak, record the
   gap, fix the network, then either resume (if gobot recovered cleanly on its own,
   logging `all probes OK`) or restart the clock (if the process had to be touched).
3. If credentials expired during the outage and did not auto-refresh, run `gobot
   reauth`, re-run pre-soak checks, and restart the clock.

### 6.4 General crash loop / wrapper failure

**Trigger:** the gobot process exits and the `start_gobot.ps1` restart loop cannot
keep it up, or Task Scheduler's own `RestartCount` exhausts (the task itself keeps
relaunching), or doctor reports a critical (`[ERR]`) check.

**Rollback:**
1. Stop the task; capture `gobot.log`, `gobot-startup.log`, and the Task Scheduler
   operational event log as failure evidence.
2. Run `gobot doctor` and remediate the specific critical check that failed (storage
   root, workspace writable, security store, or llm api key).
3. This indicates a genuine defect or environment fault  -  file it against the
   appropriate follow-up backlog item (C-306..C-314) rather than papering over it.
   The soak is **FAIL** for this run; restart the clock after the root cause is fixed.

---

## 7. Soak Evidence Artifacts (deliverables at Day 30)

- `doctor-day0.txt` and `doctor-day30.txt` (and weekly snapshots).
- `soak-log.csv` (daily signal rows).
- Computed uptime % with the calculation shown.
- Event-log and `gobot-startup.log` excerpts covering every launch.
- An incident list: each error/alert/network-test event with cause and resolution.
- Final PASS/FAIL determination against Section 4, signed and dated by the operator.
