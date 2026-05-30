# Multi-Model Routing Audit (C-304)

Status: Audit complete
Scope: `internal/provider/`, `internal/config/`, routing consumer wiring in `internal/app/`
Date: 2026-05-30

This is an **audit chore**. No production code was changed. Identified gaps are
reported below as follow-up backlog candidates rather than fixed in place.

---

## 1. Routing Paths

Gobot's multi-model routing is implemented as a decorator provider
(`RoutingProvider`) that sits in front of two underlying `Provider`s — a cheap
**manager** model and the full **executor** model — plus an unconditional
`openrouter/`-prefix bypass.

### Wiring / construction
- `internal/provider/factory.go` — `Factory.InitAll` registers concrete
  providers (gemini, anthropic, openai, openrouter) for which an API key/base
  URL is present, then calls `setupRouting` **only if**
  `cfg.Strategic.Routing.Enabled` is true.
- `setupRouting`:
  - executor provider = `cfg.DefaultProvider()` (resolved via `Get`).
  - manager provider = `rCfg.ManagerProvider`, falling back to the executor
    provider name when empty.
  - constructs `NewRoutingProvider(execProv, mgrProv, rCfg)` and registers it
    under the name `"routing"`.
  - If routing setup fails, it logs a warning and continues with direct
    providers (non-fatal).
- `internal/app/bootstrap.go` — `InitProviders` selects the active provider:
  1. `provName = cfg.DefaultProvider()`, `model = cfg.DefaultModel()`.
  2. If `model` has prefix `openrouter/`, `provName = "openrouter"`.
  3. If `cfg.Strategic.Routing.Enabled` and `Get("routing")` succeeds, return the
     routing provider. Otherwise return the named direct provider.

### Per-turn decision flow (`RoutingProvider.Chat`, `internal/provider/routing.go`)
1. **`openrouter/` prefix bypass** — if `req.Model` starts with `openrouter/`
   and an `openrouter` provider is registered, the request is sent directly to
   it. This check runs **before** the `Enabled` gate.
2. **Disabled gate** — if `cfg.Enabled == false`, delegate straight to the
   executor.
3. **Conversational heuristic** — if `len(req.Tools) == 0` AND
   `len(lastMsg) < 100`, handle the turn with the manager directly
   (`managerChat`), skipping classification.
4. **Classification turn** — otherwise call the manager with a fixed system
   prompt ("Does the user message require tool execution, deep technical
   analysis, or complex reasoning? Reply ONLY with 'YES' or 'NO'.") sending only
   the last user message.
   - Manager error → fall back to executor (`executorChat`).
   - `YES` → executor handles full turn (with tools).
   - Not `NO` (ambiguous/malformed) → fall back to executor, log warning.
   - `NO` → manager handles the full turn with tools stripped (`managerChat`).
5. **`managerChat`** copies the request, forces `Model = cfg.ManagerModel`, and
   nils out `Tools`.

### Per-specialist sub-agent routing (related, separate path — F-038)
- `internal/app/spawn_tool.go` + `internal/app/tools.go`
  (`buildSpecialistModels`) build a `map[agentType]model` from
  `cfg.Agents.Specialists`. The spawn tool resolves a per-specialist model
  before spawning a sub-agent. This is a distinct routing mechanism from the
  manager/executor cost router and is **not** integrated with `RoutingProvider`.

---

## 2. Configuration Knobs

`RoutingConfig` (`internal/config/config.go`, embedded in
`StrategicConfig.Routing`, JSON `strategic_edition.routing`):

| Knob | JSON | Type | Effect |
|---|---|---|---|
| Enabled | `enabled` | bool | Master switch. Gates both `setupRouting` registration and the `InitProviders` selection. |
| ManagerModel | `manager_model` | string | Model name forced for manager classification + manager-handled turns. |
| ManagerProvider | `manager_provider` | string | Provider for the manager; empty → falls back to executor provider name. |

Related defaults that participate in routing:

| Function | Default | Source |
|---|---|---|
| `DefaultProvider()` | `"gemini"` (also when `""`/`"auto"`) | `internal/config/config.go:480` |
| `DefaultModel()` | `"gemini-3-flash-preview"` | `internal/config/config.go:472` |
| `SpecialistProvider(name)` | falls back to `DefaultProvider()` | `internal/config/config.go:490` |

Documented in `docs/configuration.md` under
`#### Routing (strategic_edition.routing)`.

---

## 3. Model-Selection Defaults (observed)

- Routing is **off by default** (`enabled` defaults to the Go zero value
  `false`; archived F-102 explicitly specifies opt-in).
- Executor model = whatever `DefaultModel()` resolves to
  (`gemini-3-flash-preview` unless overridden).
- Manager model = `cfg.ManagerModel` verbatim; there is **no default** — if
  unset it is the empty string (see Gap G-2).
- `openrouter/`-prefixed models always bypass to the openrouter provider,
  regardless of routing enablement.

---

## 4. Behavior Verification

Focused tests in `internal/provider/routing_test.go` cover the routing matrix.
All pass:

```
go test ./internal/provider/... -run Routing -count=1
ok  github.com/allthingscode/gobot/internal/provider  0.212s
```

| Test | Path verified |
|---|---|
| `TestRoutingProvider_Disabled` | `Enabled=false` → executor. |
| `TestRoutingProvider_BypassConversational` | no tools + short msg → manager. |
| `TestRoutingProvider_EscalateToExecutor` | tools present, `YES` → executor. |
| `TestRoutingProvider_HandleByManager` | long msg, `NO` → manager final turn. |
| `TestRoutingProvider_FallbackOnError` | manager error → executor fallback. |
| `TestRoutingProvider_OpenRouterPrefix` | `openrouter/` prefix → openrouter. |

Full provider package also green: `go test ./internal/provider/... -count=1 → ok`.

**Coverage gaps in tests** (documented, not fixed): the ambiguous/malformed
classification branch (`decision` not in {YES,NO}) and the
`ManagerModel == ""` case are not directly asserted.

---

## 5. Comparison Against Archived Intent

Archived sources reviewed: `F-038_Per_Specialist_Model_Routing`,
`F-102_Manager_Executor_Cost_Routing`, `F-116_Manager_Executor_Routing`,
`C-111_Factory_TaskId_Routing_Param` (all under `.private.archive`).

| Archived intent | Current behavior | Verdict |
|---|---|---|
| F-102: two-tier manager/executor decorator implementing `Provider` | Implemented as `RoutingProvider`. | Match |
| F-102: classification prompt wording | Matches verbatim. | Match |
| F-102: classification sends only the last user message | Matches. | Match |
| F-102: malformed/error manager response falls through to executor, logged | Implemented (warn-logged). | Match |
| F-102: structured slog decision event | `slog.Info("routing: classification result", "decision", ...)` plus per-branch logs. Field name is not the literal `routing_decision=manager|executor` from spec. | Partial (G-4) |
| F-102: conversational bypass delegates to manager **"or executor if no manager is configured"** | Bypass always uses manager; no "no manager configured" guard. | Gap (G-1) |
| F-102 sample config includes `manager_prompt` | Not implemented; system prompt is hardcoded. | Gap (G-3) |
| F-102: disabled by default | True (zero value). | Match |
| F-116: routing lives in/around `internal/provider/factory.go`, escalation on predicted tool call | `setupRouting` in factory.go; escalation via classification + tool heuristic. | Match |
| F-038: per-specialist sub-agent model routing | Implemented via `buildSpecialistModels` + spawn tool; separate from cost router. | Match (orthogonal) |
| C-111: `factory.ps1 -TaskId` routing param (pipeline tooling, not LLM routing) | Out of scope of LLM routing; mentioned in archive only as related "routing" keyword. | N/A to this audit |

---

## 6. Gaps — Follow-Up Backlog Candidates

These are reported per the acceptance criteria. They are **candidates**; no code
was changed in this audit.

- **G-1 — Conversational bypass ignores "no manager configured" case.**
  `RoutingProvider.Chat` routes the short/no-tool bypass to `manager`
  unconditionally. F-102 specified falling back to the executor when no manager
  is configured. When `ManagerModel`/`ManagerProvider` are empty, `factory.go`
  sets the manager provider equal to the executor provider, but `managerChat`
  still forces `mReq.Model = cfg.ManagerModel` (empty string), so the bypass and
  manager-final turns can dispatch an empty model name. Suggested follow-up:
  guard for an unconfigured manager and/or validate `ManagerModel` is non-empty
  when `Enabled`.

- **G-2 — No default/validation for `ManagerModel`.** There is no default and no
  config-validation error when routing is enabled but `manager_model` is blank.
  F-102 cites defaults like `claude-haiku-4-5`. Suggested follow-up: add
  validation in `internal/config/validator.go` (fail-fast) or a sane default.

- **G-3 — `manager_prompt` knob from F-102 never implemented.** The
  classification system prompt is hardcoded in `routing.go`. The archived sample
  config exposes `manager_prompt`. Suggested follow-up: either add the knob or
  update F-102/docs to record the deliberate decision to hardcode it.

- **G-4 — Decision logging does not match F-102's specified event shape.**
  F-102 asked for `routing_decision=manager|executor`. The implementation logs
  several `slog` lines with a `decision`/`model` attribute instead. Suggested
  follow-up: standardize on a single structured `routing_decision` event for
  observability/metrics dashboards.

- **G-5 — `openrouter/` prefix bypass runs even when routing is disabled and
  bypasses the wrapped executor/manager.** The prefix check precedes the
  `Enabled` gate and reaches into the **global** registry via `Get("openrouter")`
  rather than the injected providers. This is reachable only when something
  hands an `openrouter/`-prefixed model to the routing provider (note
  `InitProviders` already redirects such models to the openrouter provider
  directly, so the routing-layer branch is largely dead in the current call
  graph). Suggested follow-up: confirm intent and either remove the dead branch
  or document why the routing layer must re-handle the prefix.

- **G-6 — `RoutingProvider.Models()` can return duplicates.** When manager and
  executor resolve to the same underlying provider (the empty-`ManagerProvider`
  fallback), `Models()` concatenates both lists, double-counting models.
  Low severity. Suggested follow-up: de-duplicate by `ModelInfo.ID`.

- **G-7 — Untested branches.** Ambiguous-classification fallback and the
  empty-`ManagerModel` path lack dedicated tests. Suggested follow-up: add
  table-driven cases when G-1/G-2 are addressed.

---

## 7. Scope Confirmation

- `internal/sandbox/` is inside the declared file affinity but contains only the
  shell-exec sandbox (`config.go`, `executor_*.go`); it has **no multi-model
  routing logic**. Confirmed no routing behavior lives there.
- `internal/context/` (manager/schema/pairing) holds the strategic-message and
  context-DB types consumed by the routing request/response structs but carries
  no model-selection logic itself.
- No production Go was modified by this audit; the only worktree artifact is this
  document, placed under `internal/provider/` to stay within the declared
  file_affinity (`internal/provider/`, `internal/context/`, `internal/sandbox/`).
