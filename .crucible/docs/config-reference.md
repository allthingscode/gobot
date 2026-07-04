# Config Reference — `.crucible/config.yaml`

This is the authoritative reference for every key in `.crucible/config.yaml`. The machine-readable schema is at [`schemas/config.schema.json`](../schemas/config.schema.json). Validation is run by `powershell/validate-config.ps1`.

For a step-by-step setup guide see [get-started.md](get-started.md). For a worked example see [`examples/gobot/.crucible/config.yaml`](../examples/gobot/.crucible/config.yaml).

---

## Full annotated example

```yaml
# Installed Crucible root for this project. Must point inside this project.
# The orchestrator invokes <crucible_root>/powershell/factory.ps1.
crucible_root: ".crucible"

project:
  name: My API                            # required
  description: A Node/TypeScript REST API # required
  default_branch: main                    # required

paths:                                    # optional; if specified, all keys are required. session, workspaces, prompts, personas, and sops must start with .crucible/
  backlog:    .crucible/backlog
  session:    .crucible/session
  workspaces: .crucible/.agent-workspaces
  prompts:    .crucible/prompts
  personas:   .crucible/personas
  sops:       .crucible/sops

roles:                                    # all five roles required
  researcher:  { model_tier: fast }
  groomer:     { model_tier: fast }
  architect:   { model_tier: high-capability }
  reviewer:    { model_tier: high-capability }
  operator:    { model_tier: fast }

verification:
  quick:                                  # run after every Architect commit
    - name: test
      command: npm test
  full:                                   # run by Reviewer before approval
    - name: lint
      command: npm run lint
    - name: typecheck
      command: npx tsc --noEmit
    - name: test
      command: npm test

project_mandates:                         # required; at least one rule
  - No direct database access outside the repository layer.
  - All public functions must have JSDoc.
  - No console.log in production code; use the logger module.

file_affinity_examples:                   # optional; illustrative only
  - src/api/
  - src/services/

review:                                   # optional
  diff_tool: zed                          # optional
  editor: code                            # optional
  auto_push: false                        # optional; defaults to false
  require_green_ci: false                 # optional; defaults to false
  ci_timeout_minutes: 20                  # optional; defaults to 20
```

---

## Key reference

### `crucible_root` (required)

Path to the installed Crucible bundle for this project. In a normal install this is `.crucible`, but custom relative paths (e.g. `.dev-factory`, `tools/crucible`) are supported.

This value must point to a relative path inside the project. Applications that use Crucible must use their own installed framework folder, rather than referencing absolute or external directories, and the path must not escape the project root (no `..` segments).

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `crucible_root` | string | yes | Path to this project's installed Crucible bundle. Must be relative, safe, and contain a complete bundle structure. The orchestrator invokes `<crucible_root>/powershell/factory.ps1` from the project directory to run the pipeline. |

**Examples**:

```yaml
# Standard install
crucible_root: ".crucible"

# Custom bundle directory
crucible_root: ".dev-factory"

# Nested custom bundle directory
crucible_root: "tools/crucible"
```

---

### `project` (required)

Identity and metadata for the target project.

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `name` | string | yes | Short display name. Appears in factory output and agent prompts. |
| `description` | string | yes | One sentence describing what the project does. |
| `default_branch` | string | yes | Branch the Operator merges to. Typically `main` or `master`. |

---

### `paths` (optional)

If omitted, default paths are automatically resolved by the framework. If specified, all paths must be relative to the project root. While session and framework assets (prompts, personas, sops, workspaces) must be rooted under `.crucible/` to prevent repository pollution, the `backlog` directory may be placed anywhere in the repository (e.g. at the root level as `backlog/`).

| Key | Default | Description |
|-----|---------|-------------|
| `backlog` | `.crucible/backlog` | Contains `BACKLOG.md`, `features/`, `bugs/`, `chores/`, `blocked/`. |
| `session` | `.crucible/session` | Runtime state: handoffs, scratchpads, event logs, global session state. Gitignored. |
| `workspaces` | `.crucible/.agent-workspaces` | Root for Architect git worktrees — one per in-flight task. Gitignored. |
| `prompts` | `.crucible/prompts` | Installed prompt templates for this project. Edit deliberately when the project needs customized behavior. |
| `personas` | `.crucible/personas` | Installed specialist persona definitions for this project. Edit deliberately when the project needs customized behavior. |
| `sops` | `.crucible/sops` | Installed standard operating procedures for this project. Edit deliberately when the project needs customized behavior. |

The installed files are the active runtime files.

---

### `roles` (required)

Assigns a model tier to each specialist. All five roles are required.

| Role | Recommended tier | Rationale |
|------|-----------------|-----------|
| `researcher` | `fast` | Broad coverage over deep reasoning; cost-sensitive. |
| `groomer` | `fast` | Structured output from clear instructions. |
| `architect` | `high-capability` | Multi-file reasoning, architectural decisions. |
| `reviewer` | `high-capability` | Deep code review, spec validation, regression detection. |
| `operator` | `fast` | Deterministic deployment steps; low ambiguity. |

**`model_tier` values:**

| Value | Maps to |
|-------|---------|
| `fast` | Cost-effective models (e.g. Haiku, Gemini Flash) |
| `high-capability` | High-reasoning models (e.g. Opus, Gemini Pro) |

> **Note:** `roles.*.model_tier` is legacy and superseded by the `models:` block below, which the factory's `[RECOMMENDED MODEL]` computation actually reads. `validate-config.ps1` still warns if a tier value is unused, so the block is retained for now.

---

### `models` (optional)

Concrete models per CLI target and capability tier. The factory computes an abstract tier (`strong` / `default` / `light`) from the phase, `budget_tier`, and `design_required` (see `docs/policy.md` §2.3), then resolves it **here** for the active `-Target`. This block is the single source of truth the `[RECOMMENDED MODEL]` line reads, and is the place to edit as providers release new models.

```yaml
models:
  default_target: claude
  targets:
    claude:
      strong: opus
      default: sonnet
      light: haiku
    codex:
      strong: gpt-5.5
      default: gpt-5.5
      light: gpt-5.4
    antigravity:
      strong: "Gemini 3.1 Pro (High)"
      default: "Gemini 3.5 Flash (High)"
      light: "Gemini 3.5 Flash (Medium)"
```

- **Targets**: `claude` | `codex` | `antigravity`. The default `-Target agent` uses the `claude` row.
- **Resolution order**: a value in this block wins; if absent, the framework default map (same values shown above) applies; an unknown target/tier degrades to the tier token rather than throwing. The block is optional — omit it and the defaults apply.
- **Quoting**: quote any value containing spaces (e.g. the Antigravity labels).
- **Codex auth note**: `-codex`-suffixed slugs (`gpt-5.x-codex`) require an API-key account. ChatGPT-login Codex accepts the plain `gpt-5.x` slugs; reasoning effort is set separately in `~/.codex/config.toml`, not in the model slug.
- **Dispatching Codex as a specialist**: when a phase is run by Codex (not Claude), the orchestrator launches it with `powershell/launch-codex-specialist.ps1`, which wraps `codex exec -s danger-full-access` and reports an explicit `STATUS=SUCCESS`/`STATUS=LAUNCH_FAILED` (so a broken runtime is never mistaken for a verdict). Run `launch-codex-specialist.ps1 -Preflight -Model <codex-model>` first. See `docs/orchestrators/CLAUDE.md` and `docs/orchestrators/codex.md`.

---

### `verification` (required)

Shell commands the Reviewer runs to verify Architect work. These must match your project's language and toolchain exactly. The factory does not supply defaults — every project configures its own commands.

#### `verification.quick`

Run after every Architect commit. Kept fast — typically just the test suite.

```yaml
verification:
  quick:
    - name: test
      command: npm test
```

#### `verification.full`

Run by the Reviewer before approval. Should mirror your CI pipeline exactly. A change that passes `full` locally should also pass CI.

```yaml
verification:
  full:
    - name: lint
      command: npm run lint
    - name: typecheck
      command: npx tsc --noEmit
    - name: test
      command: npm test
```

#### `verification.config_check`

Optional. Custom command to check/validate project configurations, e.g. checking config file canonical formatting. If configured, this runs as part of the `full` verification mode.

```yaml
verification:
  config_check:
    name: config check
    command: go run -mod=readonly ./cmd/gobot config reformat --check config.sample.json
```

Each step:

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `name` | string | yes | Label shown in factory output and Reviewer reports. |
| `command` | string | yes | Shell command to run. Must not contain scaffold placeholder values (`replace-with-...`). |

**Language examples:**

```yaml
# Go
verification:
  quick:
    - { name: test, command: "go test ./..." }
  full:
    - { name: vet,  command: "go vet ./..." }
    - { name: lint, command: "golangci-lint run ./..." }
    - { name: test, command: "go test ./..." }
    - { name: mod-tidy, command: "go mod tidy -diff" }

# Python
verification:
  quick:
    - { name: test, command: pytest }
  full:
    - { name: lint,     command: "ruff check ." }
    - { name: typecheck, command: "mypy ." }
    - { name: test,     command: pytest }

# Rust
verification:
  quick:
    - { name: test, command: "cargo test" }
  full:
    - { name: fmt,    command: "cargo fmt --check" }
    - { name: clippy, command: "cargo clippy --all-targets" }
    - { name: test,   command: "cargo test" }

# TypeScript / Node
verification:
  quick:
    - { name: test, command: "npm test" }
  full:
    - { name: lint,      command: "npm run lint" }
    - { name: typecheck, command: "npx tsc --noEmit" }
    - { name: test,      command: "npm test" }
```

---

### `project_mandates` (required)

A list of project-specific engineering rules that every specialist must respect. The Reviewer checks these during scope validation (checklist step 6). At least one entry is required.

```yaml
project_mandates:
  - No direct database access outside the repository layer.
  - All public functions must have JSDoc.
  - No console.log in production code; use the logger module.
```

Write mandates as declarative constraints, not instructions. The Architect reads them to understand what is forbidden; the Reviewer reads them to verify nothing was violated.

---

### `file_affinity_examples` (optional)

Illustrative examples of package paths or glob patterns used in `file_affinity` declarations. These are documentation for the Groomer, not enforcement — they show what path scopes look like in this project.

```yaml
file_affinity_examples:
  - src/api/
  - src/services/
  - tests/integration/
```

The Groomer declares actual `file_affinity` per task in the spec frontmatter. This field just provides examples to make those declarations consistent.

---

### `review` (optional)

Settings related to human review workflows.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `diff_tool` | string | (empty) | Visual diff tool command prefix (e.g. `zed`, `code`). |
| `editor` | string | (empty) | Code editor command prefix for opening worktrees. |
| `auto_push` | boolean | `false` | Whether to automatically push merged changes to `origin` remote upon acceptance. |
| `require_green_ci` | boolean | `false` | Whether accepted, auto-pushed tasks must wait for adopter CI on the merge commit before finalizing. |
| `ci_timeout_minutes` | integer | `20` | Maximum minutes to wait for adopter CI before treating unfinished runs as advisory timeout. |

---

## Validation

Run before starting any pipeline work:

```powershell
./powershell/validate-config.ps1 -ConfigPath .crucible/config.yaml
```

**Errors** (exit 2 — pipeline will not start):
- Any required section or field is missing
- `crucible_root` is absolute, contains `..` path traversal segments, or does not point to a complete installed Crucible bundle (missing `docs`, `prompts`, `personas`, `schemas`, `sops`, or `powershell` directories)
- Any path under `paths` (except `backlog`) does not start with `.crucible/`
- `paths.backlog` is absolute or contains `..` path traversal segments
- Any `verification` command still contains a scaffold placeholder (`replace-with-...`)

**Warnings** (exit 0 — pipeline starts, but check these):
- Neither `fast` nor `high-capability` is used by any role
- `project_mandates` still contains the scaffold placeholder text

---

## What to commit vs. ignore

The project-local `.crucible/.gitignore` (created by `init-project.ps1`) handles this automatically. See [git-policy.md](git-policy.md) for the full rationale.

**Principle**: configuration in, data out. Treat `.crucible/` like an app directory — commit how the system is set up, ignore its operational data.

| Path | Commit | Why |
|------|--------|-----|
| `.crucible/config.yaml` | Yes | Configuration |
| `.crucible/.gitignore` | Yes | The policy file itself |
| `.crucible/docs/` | Yes | Installed manuals, policies, and runbooks |
| `.crucible/personas/` | Yes | Installed specialist behavior |
| `.crucible/sops/` | Yes | Installed specialist workflows |
| `.crucible/prompts/` | Yes | Installed prompt templates |
| `.crucible/schemas/` | Yes | Installed validation schemas |
| `.crucible/powershell/` | Yes | Installed runtime scripts |
| `.crucible/backlog/` | No | Backlog items are data (tickets), not structure |
| `.crucible/session/` | No | Runtime state; regenerated each session |
| `.crucible/.agent-workspaces/` | No | Git worktrees; created and deleted by factory |
| `.crucible/locks/` | No | Ephemeral file locks |
| `.crucible/research/` | No | Generated artifacts |
| `.crucible/dev-logs/` | No | Generated artifacts |
